import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - What a hit test reports

/// A control found by hit-testing a screen point, in the terms the confirm card needs.
///
/// The card must be able to say what will *actually* be pressed rather than what the model
/// guessed, because the model's label comes from pixels: it saw a blue shape and called it
/// "Run". This is the element's own name, read from the app.
public struct AXElementInfo: Equatable, Sendable {
    public var pid: Int
    public var appName: String?
    public var role: String?
    public var title: String?
    public var descriptionText: String?
    /// Frame in **global top-left logical points** — the space Accessibility reports. Not
    /// stored as `LogicalRect` only because `CGRect` is what the AX value bridge hands back;
    /// no conversion happens here.
    public var frame: CGRect?
    /// Whether anything on the walk up from the hit point answers to `AXPress`/`AXPick`.
    ///
    /// The confirm card must never be shown for an element that cannot be pressed. Chromium
    /// surfaces are the common case: a point over a web page resolves to an unnamed `AXGroup`
    /// whose only useful attribute is the *window title*, so without this flag Chunks asks
    /// "Press (494) 🚨BREAKING … – Google Chrome?" and then does nothing when the press fails.
    public var isPressable: Bool

    /// How long a control name the card will show. A tab title is not a control name, and one
    /// line of 12 pt type is what the question row is measured at.
    static let labelCharacterBudget = 42

    public init(pid: Int, appName: String? = nil, role: String? = nil, title: String? = nil,
                descriptionText: String? = nil, frame: CGRect? = nil, isPressable: Bool = false) {
        self.pid = pid
        self.appName = appName
        self.role = role
        self.title = title
        self.descriptionText = descriptionText
        self.frame = frame
        self.isPressable = isPressable
    }

    /// The element's own name, falling back to its role and then to a phrase. Never empty:
    /// a card reading "Press ``?" is worse than one reading "Press button".
    public var elementLabel: String {
        for candidate in [title, descriptionText, role] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed.count > Self.labelCharacterBudget
                    ? String(trimmed.prefix(Self.labelCharacterBudget)).trimmingCharacters(in: .whitespaces) + "…"
                    : trimmed
            }
        }
        return "that control"
    }

    /// The untruncated name, for decisions that must not miss a word past the display budget: a
    /// commitment word at character 60 is still a commitment (AUDIT.md A-08). The card keeps the
    /// bounded label; the policy reads this one.
    public var fullLabel: String {
        for candidate in [title, descriptionText, role] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return "that control"
    }

    /// Everything `PolicyGate` needs. `bundleID` is supplied by the caller, which has
    /// `NSRunningApplication`; this layer only knows pids.
    public func policyTarget(bundleID: String?) -> ActionTargetInfo {
        ActionTargetInfo(bundleID: bundleID, appName: appName,
                         role: role, elementLabel: elementLabel, fullLabel: fullLabel)
    }
}

/// A window as the window server lists it: a pid, a stacking layer, and bounds in the
/// global top-left space the Accessibility hit test wants.
public struct WindowRecord: Equatable, Sendable {
    public var pid: Int
    public var layer: Int
    public var bounds: CGRect
    public var ownerName: String?

    public init(pid: Int, layer: Int, bounds: CGRect, ownerName: String? = nil) {
        self.pid = pid
        self.layer = layer
        self.bounds = bounds
        self.ownerName = ownerName
    }
}

// MARK: - The driver

/// Finds and presses a control through Accessibility **without moving the real cursor**.
///
/// Two deliberate choices define this file:
///
/// 1. **`AXUIElementPerformAction`, never a synthetic mouse event.** A `CGEvent` click has to
///    be aimed at a location, and the only reliable way to aim one is to warp the pointer
///    first — which is exactly what the user watches Chunks *not* do. The plan's fallback
///    ladder (per-window event → per-pid event → global HID) is not implemented here, and
///    that is the point: the last rung moves the real cursor, so each rung needs its own
///    policy conversation before it exists.
/// 2. **A press needs the *pressable* element, not the element under the pixel.** Hitting the
///    text inside a button, or the icon inside a toolbar item, returns a child that answers to
///    no action at all. Walking to the nearest ancestor that responds to `AXPress` (or
///    `AXPick`, for menu items) is what makes a 2-pixel aim error harmless instead of a no-op.
///
/// Everything that can be decided without a screen — which windows are even eligible, which
/// point is inside which window — is a pure function over `WindowRecord`, so it can be tested
/// with synthetic records. `TestRunner` covers those; the AX calls themselves need a granted,
/// running app, which is what `--probe-ax` is for.
public enum AXTDriver {

    /// How far up the hierarchy to look for something that answers to an action. Six covers a
    /// label inside a group inside a toolbar inside a window; past that the ancestor is the
    /// window or the app, and pressing those is not a thing.
    static let maxAncestorWalk = 6

    /// Actions that mean "activate this control". Deliberately nothing that moves focus or
    /// scrolls — this is a press, not a general remote control.
    ///
    /// `AXOpen` is the one that makes desktop and Finder-icon targets work. Read off a live
    /// machine: every icon on the desktop is an `AXImage` whose only activation actions are
    /// `AXOpen` and `AXShowMenu` — no `AXPress` at all. Without this entry Chunks answered
    /// "click the Pluralsight icon" with *that is not a control Chunks can press*, which is a
    /// capability gap reported to the user as a refusal. It is a literal because
    /// ApplicationServices declares no constant for it.
    ///
    /// Advertising an action is not the same as performing it: the live desktop dump above shows
    /// `AXOpen` on every icon, and the first press of it returned `-25205` with nothing opened,
    /// because the icon was not the selection. Hence `shouldSelectFirst`.
    static let pressActions: [String] = [kAXPressAction, kAXPickAction, "AXOpen"]

    /// An AX round trip can hang on an unresponsive app. Half a second, because the user is
    /// already waiting on the model, and a dead app must not freeze the notch.
    static let messagingTimeout: Float = 0.5

    // MARK: Outcome

    public enum PressResult: Equatable, Sendable {
        case pressed(element: AXElementInfo, action: String)
        /// The app answered the press with an error and then plainly did the thing anyway.
        ///
        /// The action's return code is an app's bookkeeping, not its behaviour — so when the code
        /// says "badly" and the effect is on screen (focus moved, or the app the user named just
        /// started), the effect is the better evidence and the user is told the truth: it worked.
        /// The code is kept for the log.
        case landedByEffect(element: AXElementInfo, action: String, code: Int)
        case permissionMissing
        case noWindow(containing: CGPoint)
        case noElement(containing: CGPoint)
        case notPressable(element: AXElementInfo)
        /// `action` is the verb that was performed and `advertised` what the element claimed to
        /// support. Without them a failure code is unreadable: `-25205` says the same thing about
        /// `AXPress` and about `AXOpen`, and only one of those is worth acting on.
        case actionFailed(code: Int, action: String, advertised: [String], element: AXElementInfo)

        /// Whether a press actually happened. Written so a caller that forgets to branch
        /// cannot accidentally report success.
        public var didPress: Bool {
            switch self {
            case .pressed, .landedByEffect: return true
            default: return false
            }
        }

        /// One line for the card and the log. Failing loudly about *why* nothing happened is
        /// the difference between a feature that looks broken and one that is broken.
        public var userFacingReason: String {
            switch self {
            case .pressed(let element, _):
                return "Pressed \(element.elementLabel)."
            case .landedByEffect(let element, _, _):
                return "Pressed \(element.elementLabel)."
            case .permissionMissing:
                return "Chunks needs Accessibility access to press anything. Grant it, then Restart."
            case .noWindow:
                return "There is no app window there, so there is nothing to press."
            case .noElement:
                return "That app did not expose a control at that point."
            case .notPressable(let element):
                // Says which app is uncooperative, because "cannot be pressed" reads like Chunks
                // refusing. The usual cause is a Chromium-based app that has not published its
                // web content to Accessibility, and the user can check that in System Settings.
                return "That is not a control Chunks can press — "
                    + "\(element.appName ?? "that app") does not expose it to Accessibility."
            case .actionFailed(let code, let action, let advertised, let element):
                // Names the verb, the code as a word and the number, and the element's own list,
                // because "the app refused" is only actionable if the next reader can see whether
                // Chunks asked for a verb the control never advertised (a bug here) or asked for
                // the one it did advertise and was refused anyway (a bug in that app).
                let claimed = advertised.isEmpty ? "nothing" : advertised.joined(separator: ", ")
                return "\(element.appName ?? "That app") would not press \(element.elementLabel) "
                    + "(\(action) → \(AXTDriver.errorCodeName(code)), code \(code); "
                    + "the control advertises \(claimed))."
            }
        }
    }

    // MARK: Pure window selection

    /// Keep only the windows a press may legitimately target.
    ///
    /// Two exclusions, both of which produce a plausible-but-wrong hit if left in:
    ///
    /// - **Our own pid.** Chunks' notch card and panels are layer 0 windows on screen. Without
    ///   this filter, "press the Allow button" could resolve to the card the user is being
    ///   asked to read, and Chunks would answer its own question.
    /// - **Every layer but 0.** Normal app windows live at 0; the menu bar, notifications,
    ///   floating panels and menus sit above it. Only 0 is what the user thinks of as "that
    ///   window".
    ///
    /// `includeDesktop` widens that second rule to the layers *below* 0, which is where the
    /// Finder desktop and the wallpaper live. It exists because "click the file on my desktop"
    /// is an instruction about a thing the user can see, and a candidate list that stops at
    /// layer 0 answers it with "there is no app window there". Menus, notifications and panels
    /// stay out: they are above 0, and pressing through one would act on a surface the user
    /// cannot see behind the modal.
    public static func candidateWindows(from entries: [[String: Any]],
                                        ownPID: Int,
                                        includeDesktop: Bool = false) -> [WindowRecord] {
        var out: [WindowRecord] = []
        for entry in entries {
            guard let rawPID = entry[kCGWindowOwnerPID as String] as? Int,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            if rawPID == ownPID { continue }
            if layer != 0 && !(includeDesktop && layer < 0) { continue }
            if bounds.width < 1 || bounds.height < 1 { continue }

            let owner = entry[kCGWindowOwnerName as String] as? String
            out.append(WindowRecord(pid: rawPID, layer: layer, bounds: bounds, ownerName: owner))
        }
        return out
    }

    /// The window the user can actually see at `point`.
    ///
    /// `CGWindowListCopyWindowInfo` returns windows front-to-back, so the **first** candidate
    /// containing the point wins — not the smallest, not the most recently focused. Searching
    /// by area would pick the window behind a dialog and press through it.
    public static func topmostWindow(_ candidates: [WindowRecord],
                                     containing point: CGPoint) -> WindowRecord? {
        candidates.first { $0.bounds.contains(point) }
    }

    // MARK: Live window list

    public static func currentWindowCandidates() -> [WindowRecord] {
        let option: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return candidateWindows(from: list,
                                ownPID: Int(ProcessInfo.processInfo.processIdentifier))
    }

    /// The layer-0 list plus the desktop beneath it, in that order.
    ///
    /// `.excludeDesktopElements` is what drops the Finder desktop from the ordinary list, so the
    /// second read has to leave it off. It is a separate call rather than a widening of the first
    /// because a hit test must prefer a real window over an icon behind it, and front-to-back
    /// order within one combined list does not express that.
    public static func currentWindowCandidatesIncludingDesktop() -> [WindowRecord] {
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        let normal = currentWindowCandidates()
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]]
        else { return normal }
        let desktop = candidateWindows(from: list, ownPID: ownPID, includeDesktop: true)
            .filter { $0.layer < 0 }
        return normal + desktop
    }

    /// The window the user can actually see at `point`, desktop included.
    static func window(at point: CGPoint) -> WindowRecord? {
        let candidates = currentWindowCandidatesIncludingDesktop()
        return topmostWindow(candidates, containing: point)
    }

    // MARK: Naming a target the pixel missed

    /// A pressable element reduced to what a name match needs: its own title and where it is.
    public struct NamedElementMatch: Equatable, Sendable {
        public var title: String
        /// Global top-left logical points, straight from the AX value bridge.
        public var frame: CGRect?

        public init(title: String, frame: CGRect? = nil) {
            self.title = title
            self.frame = frame
        }
    }

    /// How well an element's own name answers the label the model used.
    ///
    /// The model's label comes from pixels, so it is a *description* ("desktop screenshot",
    /// "pluralsight app") while an element's title is a *name* ("Screenshot 2026-09-13 at
    /// 9.09.04 PM", "Pluralsight"). Token overlap is what bridges those, and an exact title wins
    /// outright. Returns 0 when nothing in common survives: no match, not a weak one.
    public static func nameScore(label: String, title: String) -> Int {
        let labelTokens = tokens(in: label)
        let titleTokens = tokens(in: title)
        guard !labelTokens.isEmpty, !titleTokens.isEmpty else { return 0 }
        if labelTokens == titleTokens { return 3 }
        if Array(titleTokens.prefix(labelTokens.count)) == labelTokens { return 2 }
        return labelTokens.contains(where: { titleTokens.contains($0) }) ? 1 : 0
    }

    /// The words that carry meaning in a name: lowercase, punctuation dropped, filler removed.
    ///
    /// "the", "click" and "open" are in here because a model's label is a *sentence* — "click
    /// the pluralsight app" — and matching on "click" would let any control win. Dates and bare
    /// numbers go too, so a screenshot's timestamp never out-matches its kind.
    static let ignoredNameWords: Set<String> = [
        "the", "a", "an", "on", "in", "at", "of", "to", "and", "my", "this", "that",
        "click", "press", "open", "tap", "app", "apps", "application",
        "icon", "icons", "file", "files", "button", "picture", "image",
    ]

    static func tokens(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 && !ignoredNameWords.contains($0) && !$0.allSatisfy(\.isNumber) }
    }

    /// The index of the candidate that best answers `label`, or nil when none does.
    ///
    /// Ties break toward the point the model asked for, so two files with the same kind of name
    /// resolve to the one nearest the aim rather than to whichever the AX walk met first.
    public static func bestMatch(label: String,
                                 candidates: [NamedElementMatch],
                                 near point: CGPoint) -> Int? {
        struct Scored { let index: Int; let score: Int; let distance: CGFloat }
        var ranked: [Scored] = []
        for (index, candidate) in candidates.enumerated() {
            let score = nameScore(label: label, title: candidate.title)
            guard score > 0 else { continue }
            let center = candidate.frame.map {
                CGPoint(x: $0.midX, y: $0.midY)
            } ?? point
            ranked.append(Scored(index: index, score: score,
                                 distance: hypot(center.x - point.x, center.y - point.y)))
        }
        return ranked.max { ($0.score, -$0.distance) < ($1.score, -$1.distance) }?.index
    }

    /// What a point holds, or the nearest thing on it that *answers to* the name the model gave.
    ///
    /// The pixel is tried first and wins unless the control it found has a name that contradicts
    /// the label — an element under the point the model chose is the target it described, and a
    /// model aiming a few points off an icon still names the right thing. The name search is the
    /// fallback for the ways the pixel fails: an aim a row off in a list (`pixelKeepsPress`), an
    /// aim that lands on nothing pressable, and a point on the desktop, whose icons
    /// `AXUIElementCopyElementAtPosition` only resolves for the window background. It is scoped to
    /// the window at that point, and it only ever returns elements that answer to a press action,
    /// so it cannot invent a target the app has not published.
    ///
    /// Failing all of that, `desktopTarget` asks Finder. That is not a second opinion about the
    /// same pixels: the window list stops publishing the desktop as soon as an app covers it, so
    /// the ordinary route can lose the icons *because the previous turn opened something*.
    public static func target(label: String, at point: CGPoint) -> PressTarget? {
        guard isTrusted() else { return nil }
        if let window = window(at: point) {
            if let found = target(in: window, label: label, at: point) { return found }
            // Chromium and Electron — WhatsApp, Slack, VS Code, every browser tab — publish an
            // empty tree until an assistive client asks, so a control the user can see is not in
            // the tree Chunks is searching. The typing path has done this since it was written and
            // it is the only reason "type in the message box" ever finds the box; the press path
            // refusing to do the same is why four live WhatsApp turns all answered "that app did
            // not expose a control at that point" about a send button sitting in plain sight.
            let app = AXUIElementCreateApplication(pid_t(window.pid))
            _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)
            if enableManualAccessibility(on: app),
               let found = target(in: window, label: label, at: point) {
                return found
            }
        }
        return desktopTarget(label: label, near: point)
    }

    /// The pixel-first resolution, inside one window the user pointed at.
    private static func target(in window: WindowRecord, label: String, at point: CGPoint)
        -> PressTarget? {
        let app = AXUIElementCreateApplication(pid_t(window.pid))
        _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let hit = elementAtPosition(in: window, point)
        let pixel = hit.flatMap { walkToPressable(from: $0) }
            .flatMap { isOnScreen(frame(of: $0.element), in: window) ? $0 : nil }

        if let pressed = pixel, pixelKeepsPress(label: label, element: pressed.element) {
            return PressTarget(element: pressed.element,
                               info: describe(pressed.element, window: window),
                               action: pressed.action,
                               snapped: false)
        }

        if let found = searchForPressable(in: searchRoot(in: app, matching: window, hit: hit),
                                          label: label, near: point, visibleIn: window) {
            return PressTarget(element: found.element,
                               info: describe(found.element, window: window),
                               action: found.action,
                               snapped: true)
        }

        // Nothing in the window answers the name better than the point did, so the aim still wins.
        // Refusing here would break every press onto an icon or a custom control that publishes no
        // title at all, which is most of what a screenshot shows.
        guard let pressed = pixel else { return nil }
        return PressTarget(element: pressed.element,
                           info: describe(pressed.element, window: window),
                           action: pressed.action,
                           snapped: false)
    }

    /// Whether a control is somewhere the user could have been looking.
    ///
    /// Measured 2026-10-05 with `--probe-ax 900,120` over Chrome's address bar: the hit test
    /// answered an `AXMenuItem` whose frame was at y = −82 — a suggestion row from an omnibox
    /// dropdown that had already closed, still addressable in the tree. With asking switched off
    /// that is a press on a control the user cannot see, which is the one thing the confirm card
    /// exists to prevent. A frame outside the window the aim landed in is not that control.
    ///
    /// An element that publishes *no* frame stays allowed, because most desktop icons are in that
    /// set and refusing them would break the presses that work today.
    static func isOnScreen(_ frame: CGRect?, in window: WindowRecord) -> Bool {
        guard let frame else { return true }
        return window.bounds.insetBy(dx: -1, dy: -1).intersects(frame)
    }

    /// The roles that live *inside* a menu, which a name-only aim may never press.
    ///
    /// A menu item answers `AXPress` whether or not its menu is open, which makes it a perfect
    /// target for a name and a terrible one for a user who cannot see it. `isOnScreen` cannot catch
    /// it: a menu bar's rows sit on the edge of the *display*, so they are "on" it. An
    /// `AXMenuButton` is deliberately not in this set — it is the visible button that opens the menu,
    /// and refusing it would refuse a control the user was looking at.
    static func isMenuRole(_ role: String) -> Bool {
        role == "AXMenuItem" || role == "AXMenu"
    }

    /// Whether a walk should stop at this element instead of reading below it.
    ///
    /// `isMenuRole` vetoes a *found* row; this saves the reads that vetting made pointless. Measured
    /// 2026-10-28 on a live Chrome window: 479 of the 700 elements a search has spent went to menu
    /// rows that the veto would have thrown away anyway, and the page underneath was never reached.
    /// The bar's own row is not pruned from *consideration* — a visible "File" is a real control — it
    /// just does not expand, and `AXMenuButton` is neither, because that is a button the user can see.
    static func isMenuSubtree(_ role: String) -> Bool {
        isMenuRole(role) || role == "AXMenuBar" || role == "AXMenuBarItem"
    }

    /// Whether the control under the point may keep the press on the point's word alone.
    ///
    /// A control that publishes no name cannot contradict the label the user used, so the pixel
    /// stands — that is the icon case, and it is most of what a screenshot shows. A control that
    /// *does* have a name and whose name shares no word with the request is the wrong-row case
    /// measured 2026-10-05: asked for "Nitesh GVP 2" in WhatsApp's chat list, the aim landed one
    /// row down on "Tech Eximius 2026" and Chunks pressed it. Two rows in a list are 70 pt apart
    /// and a model's aim is good to about that; its *reading* of the name is far better than that,
    /// so a contradicting name is the signal to search before believing the pixel.
    static func pixelKeepsPress(label: String, element: AXUIElement) -> Bool {
        pixelKeepsPress(label: label, names: publishedNames(of: element))
    }

    /// The names an element answers to: its title, and the description apps use when the visible
    /// text lives in a child.
    static func publishedNames(of element: AXUIElement) -> [String] {
        [stringAttribute(element, kAXTitleAttribute as String),
         stringAttribute(element, kAXDescriptionAttribute as String)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    /// The same rule with the AX read taken out, so the wrong-row case is testable on any machine.
    static func pixelKeepsPress(label: String, names: [String]) -> Bool {
        guard !names.isEmpty else { return true }
        return names.contains { nameScore(label: label, title: $0) >= 1 }
    }

    /// Whether the resolved element's own name is about something else than what was asked for.
    ///
    /// Only used to word the log and the outcome line honestly: a press that landed on a
    /// differently-named control has to be reconstructable from the card, because with asking off
    /// the user never saw a question about it.
    public static func aimNamesSomethingElse(label: String, element: AXElementInfo) -> Bool {
        let names = [element.title, element.descriptionText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return false }
        return !names.contains { nameScore(label: label, title: $0) >= 1 }
    }

    /// The desktop's own icons, read straight from Finder instead of from the window list.
    ///
    /// `CGWindowListCopyWindowInfo` only lists the Finder desktop while it is an on-screen surface;
    /// measured 2026-10-04, the raw list had no Finder entry at all once another app was frontmost,
    /// which is why "click that free claude code icon" answered `nothing found` one turn after the
    /// same route had found Pluralsight. Finder keeps publishing the icons through its
    /// `AXWindows` regardless — the live dump showed `AXImage "Free Claude Code" actions=AXOpen`
    /// while an app covered the desktop — so this is the only read that works in both layouts.
    ///
    /// It asks for a *strong* name match (`desktopMinNameScore`, a prefix or an exact token set)
    /// because it crosses into a different app than the one the aim landed on: a single shared word
    /// is enough to pick a neighbour inside the window the user is looking at, and not enough to
    /// justify pressing something in another one.
    private static func desktopTarget(label: String, near point: CGPoint) -> PressTarget? {
        guard let finder = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == "com.apple.finder" })
        else { return nil }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let found = searchForPressable(in: app, label: label, near: point,
                                             minScore: desktopMinNameScore)
        else { return nil }
        let record = WindowRecord(pid: Int(finder.processIdentifier), layer: -1,
                                  bounds: frame(of: found.element) ?? .zero,
                                  ownerName: finder.localizedName ?? "Finder")
        return PressTarget(element: found.element,
                           info: describe(found.element, window: record),
                           action: found.action,
                           snapped: true)
    }

    /// A resolved press: the live element, what the card should call it, and the action to run.
    public struct PressTarget {
        public var element: AXUIElement
        public var info: AXElementInfo
        public var action: String
        /// Whether the aim missed and the *name* located it. The card and the log say so, because
        /// a press that quietly moved to a neighbouring control is the one users cannot debug.
        public var snapped: Bool
    }

    // MARK: Public API

    public static func isTrusted() -> Bool { AXIsProcessTrusted() }

    // MARK: Hit test + press

    /// Press whatever control is at `point`, given in **global top-left logical points** —
    /// i.e. the value from `ScreenshotGeometry.axGlobalPoint`. Nothing here moves the cursor.
    ///
    /// This is the strict form: only a control at that exact point may be pressed. The act path
    /// uses `target(label:at:)` + `press(_:)` instead, because the point comes from a model's
    /// guess about a picture.
    public static func press(at point: CGPoint) -> PressResult {
        guard isTrusted() else { return .permissionMissing }
        guard let window = window(at: point) else { return .noWindow(containing: point) }
        guard let hit = elementAtPosition(in: window, point) else {
            return .noElement(containing: point)
        }
        guard let resolved = walkToPressable(from: hit) else {
            return .notPressable(element: describe(hit, window: window))
        }
        return perform(resolved.element, action: resolved.action, info: describe(resolved.element,
                                                                               window: window))
    }

    /// Run a target that was already resolved and approved.
    ///
    /// A caller that wants the "the app answered badly but plainly acted" verdict has to take a
    /// `pressSnapshot` *before* calling this and then use `waitForLanding` on an ambiguous failure —
    /// `pressAct` in the shell does exactly that. It is not folded in here because the check has to
    /// wait up to seconds, and a driver that sleeps is a driver nobody expects to sleep.
    public static func press(_ target: PressTarget) -> PressResult {
        perform(target.element, action: target.action, info: target.info)
    }

    private static func perform(_ element: AXUIElement, action: String,
                                info: AXElementInfo) -> PressResult {
        let verbs = advertisedActions(on: element)
        // The caller already chose `action` from this same list, so an empty list means the target
        // went away between resolving and pressing. Perform nothing rather than guess a verb.
        guard !verbs.isEmpty else {
            return .actionFailed(code: Int(AXError.actionUnsupported.rawValue), action: action,
                                 advertised: [], element: info)
        }
        var lastCode = Int(AXError.success.rawValue)
        for verb in verbs {
            // A desktop or Finder-list icon needs selecting before it will open: what a user does
            // with a double-click is *select, then open*, and reading `actions` off a live desktop
            // icon shows `AXOpen` advertised while performing it alone comes back refused. The
            // write is best-effort — a control that rejects selection is no worse off, and the
            // press is still the thing whose result gets reported.
            if shouldSelectFirst(action: verb) {
                AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString,
                                             kCFBooleanTrue)
            }
            let error = AXUIElementPerformAction(element, verb as CFString)
            if error == .success { return .pressed(element: info, action: verb) }
            lastCode = Int(error.rawValue)
            // Only "this verb is not implemented" is safe to answer with a second verb: by that
            // answer's own words nothing ran. Any other code means the app took the request and
            // answered it badly, and asking again could act twice.
            if error != .actionUnsupported { break }
        }
        return .actionFailed(code: lastCode, action: action, advertised: verbs, element: info)
    }

    /// Whether `action` needs the element selected before it can be performed.
    ///
    /// Only `AXOpen`, because that is the verb icon surfaces answer with a refusal when the icon is
    /// not the selection — and selecting is what the user's own double-click does first. `AXPress`
    /// and `AXPick` are ordinary buttons and menu items, which hold no such requirement, and
    /// selecting a control the user never named would move focus out from under them.
    static func shouldSelectFirst(action: String) -> Bool { action == "AXOpen" }

    /// The AX code spelled out, because the number alone is not something a reader can act on.
    ///
    /// `-25205` and `-25206` differ by one and mean opposite things — the app answered the request
    /// badly versus the verb genuinely not existing — and the first live desktop press produced the
    /// former while opening the app, which is only reconstructable if the code is named.
    public static func errorCodeName(_ code: Int) -> String {
        switch code {
        case Int(AXError.success.rawValue): return "success"
        case Int(AXError.failure.rawValue): return "failure"
        case Int(AXError.illegalArgument.rawValue): return "illegalArgument"
        case Int(AXError.invalidUIElement.rawValue): return "invalidUIElement"
        case Int(AXError.invalidUIElementObserver.rawValue): return "invalidUIElementObserver"
        case Int(AXError.cannotComplete.rawValue): return "cannotComplete"
        case Int(AXError.attributeUnsupported.rawValue): return "attributeUnsupported"
        case Int(AXError.actionUnsupported.rawValue): return "actionUnsupported"
        case Int(AXError.notImplemented.rawValue): return "notImplemented"
        case Int(AXError.apiDisabled.rawValue): return "apiDisabled"
        case Int(AXError.noValue.rawValue): return "noValue"
        default: return "code \(code)"
        }
    }

    // MARK: Did the press land anyway?

    /// Return codes that mean "this app answered badly", not "nothing happened".
    ///
    /// `-25205` is `kAXErrorAttributeUnsupported` and `-25204` is `kAXErrorCannotComplete`; both
    /// are replies an app can give when it took the request and reported it badly, so the effect is
    /// unknown and worth one look. `-25206` (actionUnsupported) is deliberately absent — that one
    /// states the verb did not run at all, and `perform` answers it by trying the element's next
    /// advertised verb. A missing permission or a torn-down element never means "it worked", so
    /// waiting on those would only stall the notch.
    ///
    /// This is a *reporting* rule and nothing else: it only says "go look at the effect", and
    /// `pressLanded` is what decides whether to believe it. It cannot make a press happen.
    public static func isAmbiguousFailure(_ code: Int) -> Bool {
        code == Int(AXError.attributeUnsupported.rawValue)
            || code == Int(AXError.cannotComplete.rawValue)
            || code == Int(AXError.failure.rawValue)
    }

    /// Everything that can prove a press had an effect, read at one instant.
    ///
    /// Taken immediately *before* and again after an action whose return code was ambiguous, then
    /// diffed by `pressLanded`. Two things rather than one because the code is not the only thing
    /// that lies: a desktop icon's element belongs to **Finder**, so the app the user actually
    /// opened never appears as the pressed app's pid, and a check that only watches that pid
    /// reports a successful launch as a refusal.
    public struct PressSnapshot: Equatable, Sendable {
        /// The app the user is looking at, or `nil` when nothing owns that state.
        public var frontmostPID: Int?
        /// pid → display name of every app with a Dock presence. Background agents and daemons are
        /// left out on purpose: they are always running, so they can never look like "an app the
        /// press opened".
        public var runningApps: [Int: String]

        public init(frontmostPID: Int?, runningApps: [Int: String]) {
            self.frontmostPID = frontmostPID
            self.runningApps = runningApps
        }
    }

    public static func pressSnapshot() -> PressSnapshot {
        var names: [Int: String] = [:]
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            names[Int(app.processIdentifier)] = app.localizedName ?? ""
        }
        return PressSnapshot(
            frontmostPID: NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) },
            runningApps: names)
    }

    /// Whether the diff between two snapshots says the press did something.
    ///
    /// Two pieces of evidence, neither of which a refused action produces on its own: focus moves to
    /// a different app, or an app whose name answers what the user asked for *starts running*. The
    /// second exists because a launch does not always take focus (a dialog can hold it), and the
    /// first because an icon for an app that is already open has no new process to find. When
    /// neither holds, the failure stands.
    ///
    /// The one way this reads true without the press working is the user switching apps themselves
    /// inside the window. That is accepted deliberately: the alternative — trusting the pressed
    /// element's own pid — is what reported a real launch as a refusal, because for a desktop icon
    /// that pid is Finder's. The code the app returned stays in the log either way.
    public static func pressLanded(before: PressSnapshot, after: PressSnapshot,
                                   label: String) -> Bool {
        if let after = after.frontmostPID, after != before.frontmostPID { return true }
        for (pid, name) in after.runningApps where before.runningApps[pid] == nil {
            if nameScore(label: label, title: name) >= 2 { return true }
        }
        return false
    }

    /// Watch for the press's effect for up to `allowance` seconds.
    ///
    /// Polls because an app launched from a desktop icon does not exist in the same instant the
    /// action returns — the first real one also put up a privacy dialog, and that is seconds, not
    /// frames. Gives up rather than hanging the notch: the user is standing there waiting, and a
    /// line of text that arrives a second late reads the same as one that never arrived.
    public static func waitForLanding(label: String, before: PressSnapshot,
                                      allowance: TimeInterval = 2.5,
                                      pollInterval: TimeInterval = 0.15) async -> Bool {
        var waited: TimeInterval = 0
        while waited < allowance {
            if pressLanded(before: before, after: pressSnapshot(), label: label) { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            waited += pollInterval
        }
        return pressLanded(before: before, after: pressSnapshot(), label: label)
    }

    /// What is at `point`, without pressing it. This is what the confirm card reads so it can
    /// show the real name of the real control before the user says yes.
    public static func elementAt(_ point: CGPoint) -> AXElementInfo? {
        guard isTrusted(), let window = window(at: point),
              let hit = elementAtPosition(in: window, point)
        else { return nil }
        return describe(walkToPressable(from: hit)?.element ?? hit, window: window)
    }

    // MARK: AX hit test pieces

    /// The element Accessibility puts at a point inside a specific window's app.
    private static func elementAtPosition(in window: WindowRecord,
                                          _ point: CGPoint) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid_t(window.pid))
        _ = AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(appElement,
                                               Float(point.x), Float(point.y), &elementRef) == .success
        else { return nil }
        return elementRef
    }

    /// The element itself, or the nearest ancestor that answers to a press action.
    private static func walkToPressable(from hit: AXUIElement)
        -> (element: AXUIElement, action: String)? {
        let first = pressableWalk(from: hit)
        if let found = first.found { return found }
        guard first.stillPublishing else { return nil }
        // One more read, a layout pass later. This is not a retry of a flaky call: Chromium adds
        // `AXPress` to a web element *after* an assistive client has walked it, so the second read
        // of the same element is a different answer, and the first refusal was wrong.
        Thread.sleep(forTimeInterval: webActionRetryDelay)
        return pressableWalk(from: hit).found
    }

    /// One climb up from the hit element, and whether anything on the way looked unfinished.
    private static func pressableWalk(from hit: AXUIElement)
        -> (found: (element: AXUIElement, action: String)?, stillPublishing: Bool) {
        var current = hit
        var walked = 0
        var stillPublishing = false
        while true {
            let names = actionNames(on: current)
            if let action = pressActions.first(where: { names.contains($0) }) {
                return ((current, action), stillPublishing)
            }
            if isPublishingLazily(actions: names) { stillPublishing = true }
            guard walked < maxAncestorWalk, let parent = parent(of: current) else {
                return (nil, stillPublishing)
            }
            current = parent
            walked += 1
        }
    }

    /// The signature of a Chromium surface that has not finished publishing its actions.
    ///
    /// Measured 2026-10-05 on the live browser, at a point over a web link: the first read answered
    /// `AXShowMenu, AXScrollToVisible`, and reading *the same element* again moments later answered
    /// `AXPress, AXShowMenu, AXScrollToVisible`. The flags that used to switch a browser's full
    /// tree on are both refused — `AXEnhancedUserInterface` with `-25208` (not implemented) and
    /// `AXManualAccessibility` with `-25205` on real Chrome — so asking again is the only route.
    /// `AXScrollToVisible` is the tell because it is the one action every web element has from the
    /// first read, and no native control that can be pressed lacks it.
    static func isPublishingLazily(actions: [String]) -> Bool {
        actions.contains("AXScrollToVisible")
            && !actions.contains { pressActions.contains($0) }
    }

    /// How long to wait before the second read: long enough for Chromium's next layout pass, short
    /// enough that the user reads it as the turn taking a moment rather than as a hang.
    static let webActionRetryDelay: TimeInterval = 0.15

    /// The subtree a name search should read: the window at the point when the app publishes it,
    /// otherwise the app element itself.
    ///
    /// The desktop is the case that matters. Finder's application element has a window whose
    /// children are the icons, and searching from the app down walks *every* Finder window; the
    /// hit-tested point already told us which window the user meant.
    private static func focusedRoot(in app: AXUIElement, matching window: WindowRecord)
        -> AXUIElement {
        let windows = self.windows(of: app)
        let wanted = CGRect(x: window.bounds.origin.x, y: window.bounds.origin.y,
                            width: window.bounds.width, height: window.bounds.height)
        for candidate in windows {
            if frame(of: candidate) == wanted { return candidate }
        }
        // A desktop window is not always in `AXWindows`; fall back to whatever window owns the
        // point, then to the app's *own* idea of its front window, then to the app.
        //
        // The third step is the one that matters on WhatsApp: its app element answers `AXWindows`
        // with an empty array while `AXFocusedWindow` and `AXMainWindow` both name a real window.
        // Searching the app element instead reads a menu bar and reports "there is no text field
        // there" about the search box in the screenshot — measured 2026-10-05, when typing a
        // contact's name into that box was refused at a point that was aimed correctly.
        let aim = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        for candidate in windows {
            if frame(of: candidate)?.contains(aim) == true { return candidate }
        }
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] as [String] {
            if let windowElement = copyAttribute(app, name),
               children(of: windowElement as! AXUIElement).isEmpty == false {
                return windowElement as! AXUIElement
            }
        }
        return app
    }

    // MARK: - Semantic resolution

    /// Why a named control could not be found. Said apart because the two answers the user needs
    /// are different: "WhatsApp is not open" is fixed by opening it, "WhatsApp has no button
    /// called Send" is a wrong guess about the app.
    public enum SemanticMiss: Equatable, Error {
        case appNotOnScreen(String)
        case controlNotFound(app: String, role: String?, name: String)
        /// The name was right and the app was there, but what it found was not something to type
        /// into. Separate from `controlNotFound` because a field and a pressable control are found
        /// by different tests, and "no button called X" would be a lie about a search that was
        /// looking for a text area.
        case fieldNotFound(app: String, role: String?, name: String)
        /// The named element was found and nothing about it moves. A scroll's target is the
        /// scroller, not the row the user named, so this is a different answer from "no such
        /// control" — the control is there, it just is not a list.
        case scrollerNotFound(app: String, role: String?, name: String)
        /// Nothing in the app answered the name at all. The neutral form, for the walks whose verb
        /// is neither press nor type.
        case elementNotFound(app: String, role: String?, name: String)
        /// The ranking found the words more than once, in two different boxes, with no aim to choose
        /// between them. Separate from `controlNotFound` because the controls *are* there — saying
        /// "no control called X" about a page with two of them would send the user to look for a bug
        /// in the search rather than to name the one he meant.
        case ambiguousCandidates(app: String, name: String, matches: Int)

        /// The line the card shows and `--probe-semantic` prints, so the answer the user reads
        /// before pressing anything is the one they would get after.
        public var userFacingReason: String {
            switch self {
            case .appNotOnScreen(let app):
                return "\(app) is not on screen, so Chunks has nothing named in it to act on."
            case .controlNotFound(let app, _, let name):
                return "Chunks found no control called \"\(name)\" in \(app) that it can press."
            case .fieldNotFound(let app, _, let name):
                return "Chunks found no field called \"\(name)\" in \(app), so nothing was typed."
            case .scrollerNotFound(let app, _, let name):
                return "\"\(name)\" in \(app) is not something Chunks can scroll, so nothing moved."
            case .elementNotFound(let app, _, let name):
                return "Chunks found nothing called \"\(name)\" in \(app)."
            case .ambiguousCandidates(let app, let name, let matches):
                return "\(matches) controls in \(app) answer \"\(name)\" and Chunks cannot tell which "
                    + "one you meant — point at it, or name the one beside it."
            }
        }
    }

    /// The names one walk accepts, widest first.
    ///
    /// A field lookup carries its aliases; a press carries only what was asked for, because a press
    /// is an action and an alias is a guess.
    static func nameCandidates(for target: SemanticTarget, kind: SemanticKind) -> [String] {
        kind == .field
            ? [target.name] + SemanticTarget.fieldAliasVariants(of: target.name)
            : [target.name]
    }

    /// What a semantic walk is looking for.
    ///
    /// A press needs a verb and a type needs a role, and the two disagree more often than the names
    /// suggest: WhatsApp's search *control* answers `AXPress` and is not a field, while the field
    /// that appears after it is pressed often advertises no action at all. `.container` asks for
    /// neither, because a scroll climbs *out* of whatever the name found to reach the list that
    /// moves — an `AXList` or `AXScrollArea` usually advertises no press verb at all.
    enum SemanticKind: Equatable {
        case control
        case field
        case container
    }

    /// Find a control named in the operating system's vocabulary, with no pixel anywhere.
    ///
    /// This is the path a request takes when the model said *what* to press rather than *where*:
    /// `app=WhatsApp role=button name=Send`. Three things make it sturdier than the pixel path and
    /// one thing makes it stricter:
    ///
    /// * The app has to be running and on screen. A name in an app that is not there is a refusal,
    ///   not a search of the whole system.
    /// * Nothing in it is a coordinate, so a window that moved, a display that rescaled and a page
    ///   that reflowed cannot aim it somewhere else — and it works on a window that opened after
    ///   the screenshot was taken, which is what a multi-step plan needs.
    /// * What comes back is an element, so the press still goes through `AXUIElementPerformAction`
    ///   and the read-and-compare-before-pressing rule is unchanged.
    /// * Because there is no pixel to corroborate the guess, the name has to *really* match:
    ///   `SemanticTarget.minNameScore` is 2, so one shared word is not a licence to press.
    /// What a named walk is allowed to read, built once per request.
    ///
    /// The three walks differ only in what they accept, so the construction — frontmost window, the
    /// union-of-surfaces veto, the app element with its messaging timeout, and the roots — lives in
    /// one place. A hung app is bounded here rather than in each caller, because a named search that
    /// waits on a dead process freezes the notch mid-turn with no card to blame.
    private struct NamedSearch {
        var veto: WindowRecord
        var app: AXUIElement
        var roots: [AXUIElement]
    }

    private static func namedSearch(_ target: SemanticTarget) -> NamedSearch? {
        guard let surface = surface(ownedByNamed: target.app) else { return nil }
        let veto = WindowRecord(pid: surface.front.pid, layer: surface.front.layer,
                                 bounds: surface.visibleBounds, ownerName: surface.front.ownerName)
        let app = AXUIElementCreateApplication(CInt(surface.front.pid))
        _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return NamedSearch(veto: veto, app: app, roots: searchRoots(in: app, matching: surface.front))
    }

    public static func resolve(_ target: SemanticTarget) -> Result<PressTarget, SemanticMiss> {
        guard let search = namedSearch(target) else {
            return .failure(.appNotOnScreen(target.app))
        }

        // Two passes, and only the second one conditional. Chromium publishes an element before it
        // publishes that element's actions, so the first read can legitimately come back with
        // `AXScrollToVisible` and no `AXPress` yet; re-reading the same tree after a short wait is
        // what turns "that is not a control Chunks can press" about a working link into an answer.
        for attempt in 0...1 {
            var stillPublishing = false
            var budget = searchBudget(for: .control)
            for root in search.roots where budget > 0 {
                let found = semanticSearch(in: root, target: target, window: search.veto,
                                           kind: .control, budget: &budget)
                if let element = found.element {
                    return .success(PressTarget(element: element,
                                                info: describe(element, window: search.veto),
                                                action: advertisedActions(on: element).first ?? kAXPressAction,
                                                snapped: true))
                }
                stillPublishing = stillPublishing || found.stillPublishing
            }
            // The wait is conditional because the second pass is only worth its reads on the
            // signature that explains a miss — an element that published `AXScrollToVisible` but no
            // press verb yet. A control that is genuinely absent costs one walk, not two.
            guard attempt == 0, stillPublishing else { break }
            Thread.sleep(forTimeInterval: webActionRetryDelay)
        }
        return .failure(.controlNotFound(app: target.app, role: target.role, name: target.name))
    }

    /// The field named in the tree: the type path's twin of `resolve`.
    ///
    /// Same name rules, different acceptance test, because a field is a thing you type into rather
    /// than a thing that answers a verb. The `AXManualAccessibility` write and the retry are the
    /// ones `typeTarget` makes for the same reason — Chromium and Electron publish an empty tree
    /// until an assistive client asks, and a field that a plan's previous step just opened is not
    /// there at the instant the press returns.
    public static func typeResolve(_ target: SemanticTarget) -> Result<TypeTarget, SemanticMiss> {
        guard let search = namedSearch(target) else {
            return .failure(.appNotOnScreen(target.app))
        }
        let viaFirstResponder = focusIsUnanswerable(in: search.app, window: search.veto)

        for attempt in 0...1 {
            var budget = searchBudget(for: .field)
            for root in search.roots where budget > 0 {
                let found = semanticSearch(in: root, target: target, window: search.veto,
                                           kind: .field, budget: &budget)
                if let element = found.element {
                    return .success(TypeTarget(element: element,
                                               info: describe(element, window: search.veto),
                                               snapped: true, viaFirstResponder: viaFirstResponder))
                }
            }
            guard attempt == 0 else { break }
            enableManualAccessibility(on: search.app)
            usleep(fieldRetryPause)
        }
        return .failure(.fieldNotFound(app: target.app, role: target.role, name: target.name))
    }

    /// The list a named request points at — found by name, then climbed out of.
    ///
    /// A scroll's target is never the thing the user named: a row is not a scroller, and the model's
    /// `name=` usually describes what is *in* the list ("chat list", "the invoice table"). So this
    /// walks for the name with no verb or role requirement — an `AXList` advertises neither — and
    /// then reuses the pixel path's climb: first the ancestors that move in that direction, and only
    /// if none does the subtree below the named element. That order is the lesson measured
    /// 2026-10-05 in WhatsApp, where the nearest ancestor answering `AXDecrement` was a split group's
    /// *resize handle*.
    ///
    /// It refuses rather than searching the whole app for any scroller: moving a list the user never
    /// named is worse than moving nothing, and with asking off there is no card to catch it.
    public static func scrollResolve(_ target: SemanticTarget,
                                     direction: ActionRequest.ScrollDirection)
        -> Result<ScrollTarget, SemanticMiss> {
        guard let search = namedSearch(target) else {
            return .failure(.appNotOnScreen(target.app))
        }
        var budget = searchBudget(for: .container)
        for root in search.roots where budget > 0 {
            let found = semanticSearch(in: root, target: target, window: search.veto,
                                       kind: .container, budget: &budget)
            guard let named = found.element else { continue }
            if let choice = scrollableAncestor(of: named, for: direction)
                    ?? scrollableDescendant(in: named, for: direction) {
                return .success(ScrollTarget(element: choice.element,
                                             info: describe(choice.element, window: search.veto),
                                             action: choice.action, movesPages: choice.movesPages,
                                             snapped: true))
            }
            return .failure(.scrollerNotFound(app: target.app, role: target.role, name: target.name))
        }
        return .failure(.elementNotFound(app: target.app, role: target.role, name: target.name))
    }

    /// The on-screen surfaces of an app the user named, and the bounds a found control must be in.
    ///
    /// Frontmost, not biggest. A search that starts in whatever window happens to be largest can
    /// land in a window behind the one the user is looking at, and invariant 8 already names this
    /// class of failure: *a name can match a control the user cannot see*. Inside a window the aim
    /// chose, the pixel is the evidence; here there is no pixel, so the window has to be the one at
    /// the front.
    ///
    /// The veto is the **union** of that app's own surfaces rather than the front window alone,
    /// because a desktop icon and a document window are two surfaces of the same application. Any of
    /// them is somewhere the user could have been looking, and a control in a *different* app is
    /// unreachable anyway — the walk never leaves this app's tree.
    public struct AppSurface: Equatable, Sendable {
        public var front: WindowRecord
        public var visibleBounds: CGRect
    }

    public static func surface(ownedByNamed app: String) -> AppSurface? {
        windowListSurface(ownedByNamed: app) ?? axSurface(ownedByNamed: app)
    }

    /// Whether the application the model named is the application a window belongs to.
    ///
    /// `nameScore` alone is not enough, and the gap was the most ordinary sentence a person can
    /// say: it scores one shared token as 1 against a threshold of 2, so `app=Chrome` did not match
    /// the owner name "Google Chrome" and `app=VS Code` did not match "Code". Whole-token
    /// containment in either direction fixes both, and stays token-wise so "Mail" does not match
    /// "MailMate" and "Notes" does not match "Notion".
    static func matchesAppName(label: String, owner: String) -> Bool {
        if nameScore(label: label, title: owner) >= 2 { return true }
        let left = tokens(in: label)
        let right = tokens(in: owner)
        guard !left.isEmpty, !right.isEmpty else { return false }
        let shorter = left.count <= right.count ? left : right
        let longer = left.count <= right.count ? right : left
        return shorter.allSatisfy { longer.contains($0) }
    }

    /// Whether an app the model named is the app the hit test answered.
    ///
    /// The same half-name tolerance the named route uses — "Chrome" answers "Google Chrome" —
    /// exposed for the shell, which checks it before a *pixel* aim that came with an app qualifier
    /// is allowed to press.
    public static func appNamesMatch(_ named: String, _ owner: String) -> Bool {
        matchesAppName(label: named, owner: owner)
    }

    /// The surface as the window list reports it.
    private static func windowListSurface(ownedByNamed app: String) -> AppSurface? {
        let mine = currentWindowCandidatesIncludingDesktop()
            .filter { ($0.ownerName).map { matchesAppName(label: app, owner: $0) } ?? false }
        guard let front = mine.first else { return nil }
        var bounds = front.bounds
        for window in mine { bounds = bounds.union(window.bounds) }
        return AppSurface(front: front, visibleBounds: bounds)
    }

    /// The surface as the app itself reports it, for the case the window list has dropped.
    ///
    /// `CGWindowListCopyWindowInfo` is not a dependable description of what an app shows. Measured
    /// 2026-10-18 with `--probe-semantic app=Finder name="Free Claude Code"`: the list held six
    /// windows and no Finder in it at all, while Finder's own tree still published
    /// `AXImage "Free Claude Code" at (1616, 41) actions=AXOpen,AXShowMenu` — so the named route
    /// refused the exact ask the pixel route answers, because `desktopTarget` had learned this
    /// months ago and goes to the app element instead of through the list.
    ///
    /// The tradeoff is stated rather than hidden: an app on another Space or hidden can still be
    /// found this way, so the on-screen veto is weaker here than on the list route. What keeps it
    /// honest is the same two things that keep the desktop-icon press honest — the search never
    /// leaves that one app's tree, and a name has to score
    /// `SemanticTarget.minNameScore` with no pixel to lean on.
    private static func axSurface(ownedByNamed app: String) -> AppSurface? {
        // Every running process whose name answers, best first.
        //
        // Measured 2026-10-27: asked for the "stop sleep" tile in **Shortcuts**, the walk ran inside
        // **ShortcutsViewService** — a helper that owns a menu bar and no window — because its name
        // *starts with* the word, `nameScore` calls a prefix a 2, and `first(where:)` takes whatever
        // the process list happens to lead with. The result was a truthful-sounding refusal about a
        // control the user could see: 230 "pressable controls", every one of them a menu row.
        //
        // So the candidates are ranked, and the ranking is the one the user's sentence implies: an
        // exact name beats a prefix, and a process with a window on screen beats one without.
        let candidates = NSWorkspace.shared.runningApplications
            .filter { running in
                !isTerminated(running)
                    && (running.localizedName).map { matchesAppName(label: app, owner: $0) } ?? false
            }
            .sorted { rank($0, asked: app) != rank($1, asked: app)
                        ? rank($0, asked: app) > rank($1, asked: app)
                        : ($0.isActive && !$1.isActive) }
        guard !candidates.isEmpty else { return nil }

        for running in candidates {
            if let surface = surface(of: running, asked: app) { return surface }
        }
        // Nothing had a window. The best-named process still gets the last chance below, which is
        // the weakest veto in this file and is taken only when there is no other answer.
        return windowlessSurface(of: candidates[0], asked: app)
    }

    /// How much a running process deserves to be called "the app he named".
    private static func rank(_ running: NSRunningApplication, asked: String) -> Int {
        let name = running.localizedName ?? ""
        var score = nameScore(label: asked, title: name)
        if name.lowercased() == asked.lowercased() { score = 4 }
        if running.isActive { score += 1 }
        return score
    }

    /// One process's own window, or nil when it has none to search.
    private static func surface(of running: NSRunningApplication,
                                asked: String) -> AppSurface? {
        let element = AXUIElementCreateApplication(running.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var bounds = CGRect.zero
        var sawOne = false
        var published = windows(of: element)
        if published.isEmpty {
            // WhatsApp again, from the same measurement: its app element answers `AXWindows` with an
            // empty array while `AXFocusedWindow` names the chat window. A surface built only from
            // the window list refuses the app the user is looking at; one built only from
            // `AXWindows` does the same thing a second time.
            for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] as [String] {
                if let raw = copyAttribute(element, name) { published.append(raw as! AXUIElement) }
            }
        }
        for window in published {
            guard let frame = frame(of: window), frame.width > 0, frame.height > 0 else { continue }
            bounds = sawOne ? bounds.union(frame) : frame
            sawOne = true
        }
        guard sawOne else { return nil }
        return AppSurface(front: WindowRecord(pid: Int(running.processIdentifier), layer: 0,
                                              bounds: bounds,
                                              ownerName: running.localizedName ?? asked),
                          visibleBounds: bounds)
    }

    /// The last, weakest option: an app that answers nothing about its windows, so the only box a
    /// control can be inside is the display. It stays inside that one app's tree and still needs
    /// `minNameScore`, which is the same bargain `desktopTarget` makes for icons.
    private static func windowlessSurface(of running: NSRunningApplication,
                                          asked: String) -> AppSurface? {
        let element = AXUIElementCreateApplication(running.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(element, messagingTimeout)
        guard children(of: element).isEmpty == false else { return nil }
        let display = CGDisplayBounds(CGMainDisplayID())
        return AppSurface(front: WindowRecord(pid: Int(running.processIdentifier), layer: 0,
                                              bounds: display,
                                              ownerName: running.localizedName ?? asked),
                          visibleBounds: display)
    }

    /// `NSRunningApplication.isFinished` is the death flag; a terminating app still answers AX.
    private static func isTerminated(_ application: NSRunningApplication) -> Bool {
        application.isFinishedLaunching == false || application.isTerminated
    }

    /// The subtree a named search starts from: the front window's root, and then the app element.
    ///
    /// The window root is the precise one. The app element is there for the case `desktopTarget`
    /// had to be written for: Finder publishes its desktop icons through a surface that is not an
    /// `AXWindow`, so a search started at the window the list reports can read nothing but a menu
    /// bar and conclude the desktop is empty. The second root is only reached when the first missed,
    /// and both share one read budget.
    private static func searchRoots(in app: AXUIElement, matching window: WindowRecord)
        -> [AXUIElement] {
        let focused = searchRoot(in: app, matching: window, hit: nil)
        return CFEqual(focused, app) ? [app] : [focused, app]
    }

    /// Whether a candidate displaces the one already held.
    ///
    /// The name wins and the role only breaks a tie. Measured 2026-10-18 in WhatsApp, twice in the
    /// same log: `name=Search` resolved `AXStaticText/Search verb=AXPress`, and the same request a
    /// few minutes later — with the model having added `role=button`, as the prompt invites — was
    /// refused as "no control called Search that it can press". Catalyst calls that box a static
    /// text and it answers `AXPress`, so a hard role veto throws away a control the user can see and
    /// the name has already identified. The role still decides between two equally-named elements.
    static func displaces(score: Int, roleMatched: Bool,
                          best: (score: Int, roleMatched: Bool)?) -> Bool {
        guard let held = best else { return true }
        if score != held.score { return score > held.score }
        return roleMatched && !held.roleMatched
    }

    /// One breadth-first pass over an app's tree, looking for a named and typed control.
    ///
    /// `budget` is decremented through the roots of one attempt, because the cap that keeps a wrong
    /// guess about a huge page at well under a second only works if it counts *all* the reads — two
    /// roots each getting a fresh 220 would double the time the user waits with the notch frozen.
    private static func semanticSearch(in root: AXUIElement, target: SemanticTarget,
                                       window: WindowRecord, kind: SemanticKind,
                                       budget: inout Int)
        -> (element: AXUIElement?, stillPublishing: Bool) {
        let candidates = nameCandidates(for: target, kind: kind)
        var queue: [AXUIElement] = [root]
        var stillPublishing = false
        var best: (element: AXUIElement, score: Int, roleMatched: Bool)?

        while !queue.isEmpty, budget > 0 {
            let element = queue.removeFirst()
            budget -= 1
            let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
            let actions = actionNames(on: element)
            let answers: Bool
            switch kind {
            case .control: answers = pressActions.contains { actions.contains($0) }
            case .field: answers = isEditable(element)
            case .container: answers = true
            }

            if answers {
                let roleMatched = matchesRole(element, target: target)
                let score = candidates
                    .flatMap { candidate in publishedNames(of: element).map { published in
                        nameScore(label: candidate, title: published)
                    } }
                    .max() ?? 0
                // A closed dropdown keeps its rows addressable in the tree, so an on-screen veto is
                // not optional here: there is no aim that already chose the visible one. And the
                // veto is not enough for a menu, because a menu bar's rows sit at the edge of the
                // *display* and are therefore on it. Measured 2026-10-24: `app=Qoder name=Memora`
                // resolved `AXMenuItem/Memora at (0.0, 1107.0)`, pressed it, and opened a Finder
                // window for a folder of that name instead of switching the workspace.
                if score >= SemanticTarget.minNameScore, !isMenuRole(role),
                   isOnScreen(frame(of: element), in: window) {
                    if score == 3, roleMatched { return (element, false) }
                    if displaces(score: score, roleMatched: roleMatched,
                                 best: best.map { ($0.score, $0.roleMatched) }) {
                        best = (element, score, roleMatched)
                    }
                }
            } else if kind == .control, isPublishingLazily(actions: actions) {
                stillPublishing = true
            }
            // A menu's rows are vetoed the moment they are found, so reading them is a read that can
            // only be wasted — and measured 2026-10-28 that waste was the whole budget: 479 of a
            // Chrome window's first 700 elements were menu items, which is how `app=Chrome
            // name=Mute` refused a control sitting in the page's own player bar.
            if !isMenuSubtree(role) {
                queue.append(contentsOf: children(of: element))
            }
        }
        return (best?.element, stillPublishing)
    }

    /// Every field the named app publishes that Chunks could type into, on screen.
    ///
    /// Built because a prompt example cannot be trusted to name a control: the model reads the
    /// placeholder on the screen, and the placeholder is not necessarily the string the element
    /// publishes as its title or description. This prints the vocabulary the app actually uses, so a
    /// name that keeps being refused is measured rather than argued about.
    ///
    /// It reports how much of the tree it managed to read, because "no such field" and "I stopped
    /// looking" print the same sentence to a user. Measured 2026-10-18 on the live WhatsApp: a
    /// breadth-first walk spent its whole budget on the chat-list rows — a hundred siblings at depth
    /// two — and never reached the composer at the bottom of the window.
    public struct FieldSweep: Equatable, Sendable {
        public var fields: [AXElementInfo]
        public var elementsRead: Int
        public var budgetSpent: Bool
    }

    public static func editableFields(ownedByNamed app: String) -> FieldSweep {
        guard let surface = surface(ownedByNamed: app) else {
            return FieldSweep(fields: [], elementsRead: 0, budgetSpent: false)
        }
        let veto = WindowRecord(pid: surface.front.pid, layer: surface.front.layer,
                                bounds: surface.visibleBounds, ownerName: surface.front.ownerName)
        let appElement = AXUIElementCreateApplication(CInt(surface.front.pid))
        _ = AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        // Chromium and Electron publish an empty tree until an assistive client asks, which is the
        // same write `typeTarget` makes before it gives up on a field the user can see.
        enableManualAccessibility(on: appElement)

        var seen = Set<String>()
        var found: [AXElementInfo] = []
        var budget = maxFieldSearchElements
        for root in searchRoots(in: appElement, matching: surface.front) {
            var queue: [AXUIElement] = [root]
            while !queue.isEmpty, budget > 0 {
                let element = queue.removeFirst()
                budget -= 1
                if isEditable(element), isOnScreen(frame(of: element), in: veto) {
                    let info = describe(element, window: veto)
                    let key = "\(info.role ?? "-")|\(info.title ?? "")|\(info.descriptionText ?? "")"
                        + "|\(info.frame.map { "\($0)" } ?? "-")"
                    if seen.insert(key).inserted { found.append(info) }
                }
                queue.append(contentsOf: children(of: element))
            }
        }
        return FieldSweep(fields: found, elementsRead: maxFieldSearchElements - budget,
                          budgetSpent: budget == 0)
    }

    /// Every pressable control the named app publishes on screen, with what it actually advertises.
    ///
    /// The same reason `editableFields` exists: a refusal that says "no control called X" is only
    /// worth anything if someone can ask what the app *does* call it. Measured 2026-10-27 on the
    /// Shortcuts gallery — the "stop sleep" tile was on screen, named on screen, and the named route
    /// found nothing pressable, and no probe could say why.
    public struct ControlSweep: Equatable, Sendable {
        public struct Control: Equatable, Sendable {
            public var info: AXElementInfo
            public var subrole: String?
            /// The verbs the element itself advertises, in the order it lists them.
            public var actions: [String]
            /// The names of its children. A SwiftUI tile is routinely a pressable group whose only
            /// text is a child `AXStaticText`, and a name read from the element's own attributes
            /// alone cannot see it.
            public var childLabels: [String]

            /// The name a model should aim by: the element's own published name when it has one,
            /// otherwise the first child's words. A control whose only label is its role cannot be
            /// named, so the child's text is the only usable handle.
            public var publishedName: String {
                let own = info.fullLabel
                if own != (info.role ?? "") && own != "that control" { return own }
                return childLabels.first(where: { !$0.isEmpty }) ?? own
            }
        }

        public var controls: [Control]
        public var elementsRead: Int
        public var budgetSpent: Bool
    }

    public static func pressableControls(ownedByNamed app: String) -> ControlSweep {
        guard let surface = surface(ownedByNamed: app) else {
            return ControlSweep(controls: [], elementsRead: 0, budgetSpent: false)
        }
        let veto = WindowRecord(pid: surface.front.pid, layer: surface.front.layer,
                                bounds: surface.visibleBounds, ownerName: surface.front.ownerName)
        let appElement = AXUIElementCreateApplication(CInt(surface.front.pid))
        _ = AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        enableManualAccessibility(on: appElement)

        var found: [ControlSweep.Control] = []
        var budget = maxFieldSearchElements
        for root in searchRoots(in: appElement, matching: surface.front) {
            var queue: [AXUIElement] = [root]
            while !queue.isEmpty, budget > 0 {
                let element = queue.removeFirst()
                budget -= 1
                let actions = actionNames(on: element)
                if actions.contains(where: { pressActions.contains($0) }),
                   isOnScreen(frame(of: element), in: veto) {
                    found.append(ControlSweep.Control(
                        info: describe(element, window: veto),
                        subrole: stringAttribute(element, kAXSubroleAttribute as String),
                        actions: actions,
                        childLabels: children(of: element).flatMap { publishedNames(of: $0) }))
                }
                queue.append(contentsOf: children(of: element))
            }
        }
        return ControlSweep(controls: found, elementsRead: maxFieldSearchElements - budget,
                            budgetSpent: budget == 0)
    }

    /// The frontmost app's published state, shaped for the model's observation channel.
    ///
    /// One call so the shell can hop it in a single `driver({ … })` line — the main-thread gate
    /// recognises that shape, and a multi-line closure hid the sweeps from it. Read-only: two bounded
    /// sweeps, names only, redacted and budgeted by `ScreenStateDigest`. Returns nil with no frontmost
    /// app. This is the state-grounding observation (StateAct): the model names controls from the tree
    /// instead of reading pixels.
    public static func frontmostStateDigest() -> ScreenStateDigest? {
        guard let front = NSWorkspace.shared.frontmostApplication?.localizedName else { return nil }
        let controls = pressableControls(ownedByNamed: front).controls.map {
            ScreenStateDigest.Control(label: $0.publishedName, role: $0.info.role ?? "control")
        }
        let fields = editableFields(ownedByNamed: front).fields.map {
            ScreenStateDigest.Field(label: $0.fullLabel, role: $0.role ?? "field")
        }
        return ScreenStateDigest.block(frontmost: front, windows: [],
                                       controls: controls, fields: fields)
    }

    /// Every pressable control an app publishes, shaped for `CandidateRanker`.
    ///
    /// The same walk as `pressableControls`, with one addition that is the whole point: the words
    /// drawn *inside* each control, not only the words the control publishes about itself. On the
    /// live machine those two are rarely the same list — measured 2026-10-28 over a Chrome tab,
    /// `--probe-semantic` refused a button the user could see because every candidate's own title was
    /// empty while its child text said exactly what he had asked for.
    ///
    /// It reads with the field walk's budget, not the press walk's, and for the same reason: this
    /// route only ever runs *after* the fast walk has already missed, so the control is by definition
    /// one the cheap search failed to reach — WhatsApp's composer sat behind a hundred chat rows at
    /// the point where a 220-read walk stops.
    public struct CandidateSweep: Equatable, Sendable {
        public var candidates: [CandidateElement]
        /// The bounds every candidate has to be inside, in global top-left logical points. The union
        /// of the app's surfaces, which is the veto the named route already uses.
        public var windowBounds: CGRect
        /// The one rectangle a person is looking at: this app's largest on-screen window. A card's
        /// "at the top-left" has to be measured against that, because for Chrome the union above also
        /// covers the tab-hover strips *above* the display — measured 2026-10-28, the invisible
        /// "Mute tab" at y = −53 sits at the "top-right" of the union and nowhere on the screen.
        public var contentBounds: CGRect
        public var elementsRead: Int
        public var budgetSpent: Bool
    }

    static let maxCandidateSearchElements = 700
    /// How deep inside a control its words still count as that control's.
    ///
    /// Two, because that is how a web control is built: `AXGroup` → `AXStaticText`, sometimes with a
    /// wrapper in between. Deeper is a page, and a page contains every word the user might say.
    static let maxCandidateChildDepth = 2
    /// Reads spent looking for one control's words, so a huge subtree cannot cost the whole walk.
    static let maxCandidateChildReads = 8

    /// What `--probe-candidates` reads. The probe and the press run this same walk, so "the probe
    /// found it" and "the app would act on it" cannot become two different claims.
    public static func candidateControls(ownedByNamed app: String) -> CandidateSweep? {
        candidateSweep(app)?.sweep
    }

    /// The walk, with the live elements kept alongside the data the ranker scored.
    ///
    /// `CandidateElement` is a value and `AXUIElement` is a reference, and the ranking is only
    /// testable as values — so the two lists run in step and the chosen value is looked back up.
    /// `CandidateSweep` cannot hold the handles itself: `AXUIElement` is not `Sendable`, and this
    /// type is compared in unit tests.
    private struct CandidateWalk {
        var sweep: CandidateSweep
        var handles: [AXUIElement]
        var veto: WindowRecord
    }

    private static func candidateSweep(_ app: String) -> CandidateWalk? {
        guard let surface = surface(ownedByNamed: app) else { return nil }
        let veto = WindowRecord(pid: surface.front.pid, layer: surface.front.layer,
                                bounds: surface.visibleBounds, ownerName: surface.front.ownerName)
        let appElement = AXUIElementCreateApplication(CInt(surface.front.pid))
        _ = AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        enableManualAccessibility(on: appElement)

        var seen = Set<String>()
        var found: [CandidateElement] = []
        var handles: [AXUIElement] = []
        var budget = maxCandidateSearchElements
        // Two passes over one shared budget, exactly as the named press route does: Chromium publishes
        // an element before it publishes that element's children, so the first walk can legitimately
        // finish a whole window and never see the page inside it. Measured 2026-10-28 on a live Chrome
        // tab: pass one read 291 elements — every one of them browser chrome — and the web area handed
        // back no children at all. The budget is not refilled, because the cap is what bounds how long
        // the notch can sit frozen, whichever pass it is spending.
        for attempt in 0...1 {
            var stillPublishing = false
            for root in searchRoots(in: appElement, matching: surface.front) {
                var queue: [AXUIElement] = [root]
                while !queue.isEmpty, budget > 0 {
                    let element = queue.removeFirst()
                    budget -= 1
                    let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
                    // A menu's rows stay addressable whether or not the menu is open, so reading them
                    // is both a wasted read and the `Memora` failure one step away. Measured the same
                    // afternoon: 479 of the reads a Chrome walk has went to menu items, and the page
                    // underneath was never reached. The bar's own row stays a candidate — a visible
                    // "File" is a real control — but its subtree is neither read nor collected.
                    let isMenu = isMenuSubtree(role)
                    let actions = actionNames(on: element)
                    let verb = pressActions.first { actions.contains($0) }
                    if verb == nil, isPublishingLazily(actions: actions) { stillPublishing = true }
                    if let verb, isOnScreen(frame(of: element), in: veto) {
                        let ownNames = publishedNames(of: element)
                        let elementFrame = frame(of: element)
                        // The same element can be reached from both roots, and from both passes, and a
                        // duplicate is not a second opinion — it is a fake tie that would make
                        // `tiedTop` refuse a control the user pointed straight at.
                        let key = "\(role)|\(ownNames.joined(separator: "/"))|"
                            + "\(elementFrame.map { "\($0)" } ?? "-")"
                        if seen.insert(key).inserted {
                            found.append(CandidateElement(
                                role: role,
                                subrole: stringAttribute(element, kAXSubroleAttribute as String),
                                ownNames: ownNames,
                                childrenText: isMenu ? []
                                    : descendantText(of: element, budget: &budget),
                                frame: elementFrame,
                                pressVerb: verb))
                            handles.append(element)
                        }
                    }
                    if !isMenu {
                        queue.append(contentsOf: children(of: element))
                    }
                }
            }
            guard attempt == 0, stillPublishing, budget > 0 else { break }
            Thread.sleep(forTimeInterval: webActionRetryDelay)
            enableManualAccessibility(on: appElement)
        }
        return CandidateWalk(
            sweep: CandidateSweep(candidates: found, windowBounds: veto.bounds,
                                  contentBounds: largestWindow(ownedByNamed: app) ?? veto.bounds,
                                  elementsRead: maxCandidateSearchElements - budget,
                                  budgetSpent: budget == 0),
            handles: handles, veto: veto)
    }

    /// A press resolved by ranking the things on screen instead of matching one published name.
    ///
    /// Only ever worth calling after `resolve` has refused, and it changes nothing about what happens
    /// next: the caller still runs `PolicyGate`, still puts a question on the card, and still re-reads
    /// the control with `CandidateRanker.stillAnswers` before pressing. What is different is only
    /// *which words* Chunks was allowed to compare against — the app's own title, or the words drawn
    /// inside the control — and the card says which of the two it found, because the two are not the
    /// same claim and a user cannot check a description he does not know was inferred.
    public struct RankedPress {
        public var target: PressTarget
        public var ranked: RankedCandidate
        /// The rectangle the card's position phrase is measured against.
        public var contentBounds: CGRect
    }

    public static func candidateResolve(_ target: SemanticTarget)
        -> Result<RankedPress, SemanticMiss> {
        guard let walk = candidateSweep(target.app) else {
            return .failure(.appNotOnScreen(target.app))
        }
        let ranked = CandidateRanker.rank(label: target.name, windowBounds: walk.sweep.windowBounds,
                                          candidates: walk.sweep.candidates)
        guard let top = ranked.first else {
            return .failure(.controlNotFound(app: target.app, role: target.role,
                                             name: target.name))
        }
        if CandidateRanker.tiedTop(ranked) {
            return .failure(.ambiguousCandidates(app: target.app, name: target.name,
                                                 matches: ranked.count))
        }
        // The value the ranking chose is the only key back to the live element, and the sweep's
        // dedupe on role + names + frame is what makes it unique. No handle means the tree changed
        // between the two lists being built, which is a refusal rather than a guess.
        guard let index = walk.sweep.candidates.firstIndex(of: top.element),
              index < walk.handles.count else {
            return .failure(.controlNotFound(app: target.app, role: target.role,
                                             name: target.name))
        }
        let element = walk.handles[index]
        return .success(RankedPress(
            target: PressTarget(element: element,
                                info: describe(element, window: walk.veto),
                                action: top.element.pressVerb,
                                snapped: true),
            ranked: top, contentBounds: walk.sweep.contentBounds))
    }

    /// Every point the machine says is on a screen: the union of the active displays, in the global
    /// top-left space Accessibility speaks.
    ///
    /// A diagnostic, not a veto — and it was tried as one. Measured 2026-10-28 on this Mac: Chrome
    /// publishes its whole toolbar at y = −91, above the display's origin, so filtering candidates by
    /// this rect threw away Back, Reload and the address bar — every one of them visible, pressable
    /// and resolvable that morning — and `--probe-candidates name=Reload` went from a card to a
    /// refusal. What the measurement supports is only the weaker claim: when a control's coordinates
    /// fall outside the window the user is looking at, the card must not describe where it is.
    public static func visibleDisplayBounds() -> CGRect {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(8, nil, &count) == .success, count > 0 else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        var rect = CGDisplayBounds(ids[0])
        for id in ids.dropFirst() { rect = rect.union(CGDisplayBounds(id)) }
        return rect
    }

    /// The app's largest ordinary window, which is the rectangle the user is looking at.
    ///
    /// `surface.visibleBounds` is a union built to be a generous veto, and a generous veto is a
    /// terrible map reference: Chrome's own union reaches 114 points above the display, so a position
    /// phrase measured against it can say "at the top-right" about a control that is not on the screen.
    private static func largestWindow(ownedByNamed app: String) -> CGRect? {
        currentWindowCandidatesIncludingDesktop()
            .filter { $0.layer == 0 }
            .filter { ($0.ownerName).map { matchesAppName(label: app, owner: $0) } ?? false }
            .max { ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height) }?
            .bounds
    }

    /// The words drawn inside an element, paid for out of the same read budget as the walk.
    private static func descendantText(of element: AXUIElement, budget: inout Int) -> [String] {
        var found: [String] = []
        var queue: [(element: AXUIElement, depth: Int)] = children(of: element).map { ($0, 1) }
        var reads = 0
        while !queue.isEmpty, reads < maxCandidateChildReads, budget > 0 {
            let (next, depth) = queue.removeFirst()
            budget -= 1
            reads += 1
            found.append(contentsOf: publishedNames(of: next))
            if depth < maxCandidateChildDepth {
                queue.append(contentsOf: children(of: next).map { ($0, depth + 1) })
            }
        }
        return found
    }

    /// Does this element answer to the role the model named, in the vocabulary the app uses?
    ///
    /// Checked against role *and* subrole, because Catalyst puts the field-ness in the subrole —
    /// WhatsApp's search box publishes `role=AXStaticText subrole=AXSearchField`, and a role-only
    /// check reads it as a label and refuses to type into the field the user is looking at.
    static func matchesRole(_ element: AXUIElement, target: SemanticTarget) -> Bool {
        guard target.role != nil else { return true }
        let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
        if target.roleMatches(role) { return true }
        let subrole = stringAttribute(element, kAXSubroleAttribute as String) ?? ""
        return !subrole.isEmpty && target.roleMatches(subrole)
    }

    /// The subtree a name search may read: the window the aim's own element lives in.
    ///
    /// `focusedRoot` starts from `AXWindows`, and **WhatsApp publishes none** — measured
    /// 2026-10-05 on the live app: the app element's `AXWindows` came back empty, its `AXChildren`
    /// held a menu bar and nothing else, and yet `AXUIElementCopyElementAtPosition` answered with a
    /// real element whose second `AXParent` was an `AXWindow` with 85 nodes under it, including
    /// `AXTextArea "Compose message"` and `AXButton "Avinash Bro @CEO VoidLabs.in"`. So a name
    /// search from the app root reads an empty room and reports "that app did not expose a control
    /// at that point" about controls the user can see and click.
    ///
    /// Climbing from the hit element is the route that works for that app and costs nothing for the
    /// apps that do list windows: the same window comes back either way. A semantic request has no
    /// hit element to climb from, so this falls through to the focused window.
    private static func searchRoot(in app: AXUIElement, matching window: WindowRecord,
                                   hit: AXUIElement?) -> AXUIElement {
        var current = hit
        var climbed = 0
        while let node = current, climbed < maxAncestorWalk {
            if stringAttribute(node, kAXRoleAttribute as String) == "AXWindow",
               children(of: node).isEmpty == false {
                return node
            }
            current = parent(of: node)
            climbed += 1
        }
        return focusedRoot(in: app, matching: window)
    }

    /// How many elements a name search may read before giving up.
    ///
    /// An AX round trip costs a cross-process call, and this runs inside a turn the user is
    /// already waiting on. The cap is what keeps a wrong guess about a huge web page at well
    /// under a second instead of wedging the notch on an app with ten thousand nodes.
    static let maxNameSearchElements = 220

    /// How many reads a walk looking for a *field* or a *list* may spend.
    ///
    /// Larger, on purpose, and measured rather than tuned: 2026-10-18, the live WhatsApp had a chat
    /// open and a composer on screen, and `--probe-fields WhatsApp` read 220 elements, found no
    /// field, and reported the budget spent — every read gone on the chat-list rows, which are a
    /// hundred siblings at depth two, while the composer sits at the end of the window. A press gets
    /// the small number because its control is usually near the top of the tree and a wrong press is
    /// the dangerous failure; a missed field is only ever a refusal.
    static let maxFieldSearchElements = 700

    /// The read budget for one kind of named search.
    static func searchBudget(for kind: SemanticKind) -> Int {
        kind == .control ? maxNameSearchElements : maxFieldSearchElements
    }

    /// How much of a name match justifies pressing something in an app the aim did not land on.
    ///
    /// One shared word is enough to pick a neighbour inside the window the user is looking at — the
    /// aim already chose that app. It is not enough to reach into Finder's desktop on the strength
    /// of a description like "the claude thing", where "claude" alone matches several icons.
    static let desktopMinNameScore = 2

    /// Search a subtree for the pressable element whose name answers `label`.
    ///
    /// `minScore` is how much of a name match counts: 1 (a shared word) is enough inside the window
    /// the user is looking at, and `desktopTarget` raises it to `desktopMinNameScore` because it
    /// searches an app the aim did not land on.
    private static func searchForPressable(in root: AXUIElement, label: String,
                                           near point: CGPoint, minScore: Int = 1,
                                           visibleIn window: WindowRecord? = nil)
        -> (element: AXUIElement, action: String)? {
        let first = pressableSearchPass(in: root, label: label, near: point,
                                        minScore: minScore, visibleIn: window)
        if let found = first.found { return found }
        guard first.stillPublishing else { return nil }
        Thread.sleep(forTimeInterval: webActionRetryDelay)
        return pressableSearchPass(in: root, label: label, near: point,
                                   minScore: minScore, visibleIn: window).found
    }

    /// One breadth-first read of the subtree for a pressable element whose name answers `label`.
    private static func pressableSearchPass(in root: AXUIElement, label: String,
                                            near point: CGPoint, minScore: Int,
                                            visibleIn window: WindowRecord?)
        -> (found: (element: AXUIElement, action: String)?, stillPublishing: Bool) {
        var pressables: [(element: AXUIElement, action: String, match: NamedElementMatch)] = []
        var visited = 0
        var stillPublishing = false
        var queue: [AXUIElement] = [root]

        while !queue.isEmpty, visited < maxNameSearchElements {
            let element = queue.removeFirst()
            visited += 1

            let names = actionNames(on: element)
            if let action = pressActions.first(where: { names.contains($0) }) {
                let title = stringAttribute(element, kAXTitleAttribute as String)
                    ?? stringAttribute(element, kAXDescriptionAttribute as String) ?? ""
                let score = nameScore(label: label, title: title)
                let frame = frame(of: element)
                let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
                // A closed dropdown keeps its rows in the tree and addressable, so a name can
                // match something the user cannot see. `isOnScreen` is the veto — and it is not
                // enough for a menu, because a menu bar's items sit at the edge of the screen and
                // are therefore "on" it. Measured 2026-10-24: "click the Memora workspace" pressed
                // an `AXMenuItem` named Memora at (0, 1107) and opened a Finder window instead of
                // switching Qoder's workspace. A workspace row is an AXButton; a menu the user can
                // actually see is still reachable, because that route has a pixel to aim at.
                if score >= minScore, !isMenuRole(role),
                   window == nil || isOnScreen(frame, in: window!) {
                    pressables.append((element, action,
                                       NamedElementMatch(title: title, frame: frame)))
                    // An exact name needs no further looking: nothing can beat it.
                    if score == 3, let first = pressables.last {
                        return ((first.element, first.action), stillPublishing)
                    }
                }
            } else if isPublishingLazily(actions: names) {
                stillPublishing = true
            }
            queue.append(contentsOf: children(of: element))
        }

        guard let index = bestMatch(label: label,
                                   candidates: pressables.map(\.match),
                                   near: point) else { return (nil, stillPublishing) }
        return ((pressables[index].element, pressables[index].action), stillPublishing)
    }

    // MARK: AX reading
    //
    // Internal rather than private from 2026-11-02: `WindowDriver` reads the same attributes off the
    // same elements, and a second copy of the `AXUIElementCopyAttributeValue` bridge is a second place
    // for the "an AX array is an array of elements by contract" mistake to be reintroduced.

    static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let parent = copyAttribute(element, kAXParentAttribute as String) else { return nil }
        return parent as! AXUIElement
    }

    /// An element's children, or nothing at all.
    ///
    /// A tree walk has to treat one uncooperative app as a dead branch rather than an error: an
    /// app that fails `AXUIElementCopyAttributeValue` mid-walk is normal, and a name search that
    /// aborted on it would refuse to press the button two nodes away.
    static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let raw = copyAttribute(element, kAXChildrenAttribute as String) as? [AnyObject]
        else { return [] }
        // An AX children array is an array of elements by contract, so this is a bridge, not a
        // check — `compactMap { $0 as? AXUIElement }` is a warning that never resolves.
        return raw.map { $0 as! AXUIElement }
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        guard let raw = copyAttribute(app, kAXWindowsAttribute as String) as? [AnyObject]
        else { return [] }
        return raw.map { $0 as! AXUIElement }
    }

    static func copyAttribute(_ element: AXUIElement,
                              _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value
    }
    /// Every action name the element publishes, unfiltered.
    static func actionNames(on element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let list = names as? [String]
        else { return [] }
        return list
    }

    /// Every activation verb the element answers to, in the order Chunks prefers them.
    ///
    /// Read on a failure and put in the user-facing line, because the code alone cannot tell the
    /// next reader whether Chunks asked for a verb the control never advertised (a bug here) or
    /// asked for the one it did advertise and was refused anyway (a bug in that app).
    static func advertisedActions(on element: AXUIElement) -> [String] {
        let list = actionNames(on: element)
        return pressActions.filter { list.contains($0) }
    }

    /// The first activation action the element answers to, if any.
    ///
    /// Read from the element rather than inferred from its role, because roles lie about
    /// pressability: a custom control can be an `AXGroup` that implements `AXPress`, and a
    /// plain `AXButton` in a hung app implements nothing.
    private static func actionOn(_ element: AXUIElement) -> String? {
        advertisedActions(on: element).first
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue
        else { return nil }

        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &dimensions)
        else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func describe(_ element: AXUIElement, window: WindowRecord) -> AXElementInfo {
        AXElementInfo(pid: window.pid,
                      appName: window.ownerName,
                      role: stringAttribute(element, kAXRoleAttribute as String),
                      title: stringAttribute(element, kAXTitleAttribute as String),
                      descriptionText: stringAttribute(element, kAXDescriptionAttribute as String),
                      frame: frame(of: element),
                      isPressable: actionOn(element) != nil)
    }

    // MARK: Typing into a field

    /// A field Chunks may type into, with the metadata the card reads.
    public struct TypeTarget {
        public var element: AXUIElement
        public var info: AXElementInfo
        /// Whether the aim missed and the *name* located the field.
        public var snapped: Bool
        /// Whether the words will go to the app's first responder rather than to this element.
        ///
        /// Set only when the app cannot answer `AXFocusedUIElement` usefully — measured
        /// 2026-10-05 on WhatsApp, a Mac Catalyst app, whose focused element is an
        /// `AXGroup/iOSContentGroup` the size of the whole window. UIKit still knows exactly which
        /// text input is first responder and delivers synthetic keystrokes to it, which is why the
        /// Auto Typer script this feature was modelled on works there by clicking and typing. The
        /// alternative — insisting that the focused element be the field — means Chunks can never
        /// type into any Catalyst app, however open the field is.
        public var viaFirstResponder: Bool

        public init(element: AXUIElement, info: AXElementInfo, snapped: Bool,
                    viaFirstResponder: Bool = false) {
            self.element = element
            self.info = info
            self.snapped = snapped
            self.viaFirstResponder = viaFirstResponder
        }
    }

    public enum TypeResult: Equatable, Sendable {
        case typed(element: AXElementInfo, characters: Int)
        case permissionMissing
        /// No editable control at that point, in an app that publishes one.
        case noField(containing: CGPoint)
        /// The field would not take focus, so nothing was typed.
        ///
        /// This is the refusal that keeps typing honest. Keystrokes go to whatever the frontmost
        /// app has focused, which is not necessarily the field the user approved — so the focus is
        /// read back and compared, and a field that will not be focused ends the act here rather
        /// than sending the text somewhere else.
        case focusRefused(element: AXElementInfo)
        /// Focus was taken and the keys were posted, but the field's own value says the text is
        /// not there.
        case rejectedByField(element: AXElementInfo)
        /// The text carries line breaks and the field is one line, where a line break is a Send.
        ///
        /// His own proven typer presses Enter between lines on purpose, in an editor. In a chat
        /// composer or a search box the same keystroke submits half the code to half the wrong
        /// people, so the whole act is refused instead of typing the first line and "sending" it.
        case multilineIntoSingleLine(element: AXElementInfo, lineBreaks: Int)
        /// Keystrokes posted after a focus click into web content, which the page would not confirm.
        ///
        /// The click-then-type contract his Auto Typer proves has no receipt: a Chromium editor can
        /// take the caret and still answer nothing about its value. Said as posted-and-unconfirmed
        /// rather than as typed, because the difference is whether he needs to look at the field.
        case postedUnverified(appName: String?, characters: Int)
        /// Web content took the click but would not say what holds the caret, and the text carries
        /// line breaks — which are a Send in a one-line box, so nothing was posted at all.
        case multilineWithoutWitness(appName: String?, lineBreaks: Int)

        public var didType: Bool {
            switch self {
            case .typed, .postedUnverified: return true
            default: return false
            }
        }

        public var userFacingReason: String {
            switch self {
            case .typed(let element, let characters):
                return "Typed \(characters) characters into "
                    + "\(AXTDriver.fieldLabel(for: element))."
            case .permissionMissing:
                return "Chunks needs Accessibility access to type anything. Grant it, then Restart."
            case .noField:
                return "There is no text field there that Chunks can see, so nothing was typed."
            case .focusRefused(let element):
                return "\(element.appName ?? "That app") would not put the cursor in "
                    + "\(AXTDriver.fieldLabel(for: element)), so nothing was typed."
            case .rejectedByField(let element):
                return "\(AXTDriver.fieldLabel(for: element)) took the keystrokes and then refused "
                    + "the text, so it may not be there."
            case .multilineIntoSingleLine(let element, let lineBreaks):
                return "\(AXTDriver.fieldLabel(for: element)) is one line and the text has "
                    + "\(lineBreaks) line break\(lineBreaks == 1 ? "" : "s") — a line break there "
                    + "sends it, so nothing was typed."
            case .postedUnverified(let appName, let characters):
                return "Posted \(characters) characters into \(appName ?? "the page") at the "
                    + "click — the page would not confirm, so look at the field."
            case .multilineWithoutWitness(let appName, let lineBreaks):
                return "\(appName ?? "That page") took the click but would not say what holds "
                    + "the caret, and the text has \(lineBreaks) line break"
                    + "\(lineBreaks == 1 ? "" : "s") — a line break in a one-line box sends it, "
                    + "so nothing was typed."
            }
        }
    }

    /// Whether a text with line breaks may go into a field of this role.
    ///
    /// Pure, because the rule is arithmetic about a role string and it is the one decision here
    /// that can send a message nobody approved: a multiline editor takes newlines as newlines,
    /// everything one-line takes them as Submit.
    public enum NewlinePolicy: Equatable, Sendable {
        case ok
        case refused(lineBreaks: Int)
    }

    public static func newlinePolicy(text: String, role: String?) -> NewlinePolicy {
        let lineBreaks = text.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        guard lineBreaks > 0 else { return .ok }
        return role == "AXTextArea" ? .ok : .refused(lineBreaks: lineBreaks)
    }

    /// The roles that hold text a user types.
    ///
    /// `AXSecureTextField` is deliberately absent: a password field is refused by `PolicyGate`
    /// before it gets here, and an empty list is safer than a list someone has to remember to
    /// subtract from.
    public static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXEmailField",
    ]

    /// The same names, where Mac Catalyst apps put them: in the **subrole**.
    ///
    /// Measured 2026-10-08 on WhatsApp with its search box open and focused — the element is
    /// `role=AXStaticText subrole=AXSearchField`, advertising `AXPress`. A role-only check can
    /// never see that field, which is why five rounds of aim, focus and first-responder fixes all
    /// ended with "there is no text field there" about a box with a caret blinking in it. Catalyst
    /// is the family this matters for: WhatsApp, and every iOS app that runs on the Mac.
    public static let editableSubroles: Set<String> = editableRoles

    /// Whether a role/subrole pair is something a person types into.
    ///
    /// A secure field is refused on either half of the pair, so a Catalyst app that labels a
    /// password box `AXStaticText/AXSecureTextField` is still not typeable.
    public static func isEditableField(role: String?, subrole: String?) -> Bool {
        if let subrole, subrole == "AXSecureTextField" { return false }
        if let role, role == "AXSecureTextField" { return false }
        if let role, editableRoles.contains(role) { return true }
        if let subrole, editableSubroles.contains(subrole) { return true }
        return false
    }

    /// Whether a role is one Chunks may type into.
    public static func isEditableRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return editableRoles.contains(role)
    }

    /// Whether an element is something a person types into, role *or* subrole.
    private static func isEditable(_ element: AXUIElement) -> Bool {
        isEditableField(role: stringAttribute(element, kAXRoleAttribute as String),
                        subrole: stringAttribute(element, kAXSubroleAttribute as String))
    }

    /// What to call a field in the sentence the user reads or hears.
    ///
    /// `elementLabel` falls back to the raw AX role, which is tolerable for a control and useless
    /// for a field: measured 2026-10-05 on a live TextEdit window the element publishes no title,
    /// so the role fallback would have asked "Type … into AXTextArea?" and then said "Typed 10
    /// characters into AXTextArea." With asking off that line is the *only* report the user gets,
    /// so it has to be English. A field that does have a name keeps it, because that name is what
    /// the user looked at and agreed to.
    public static func fieldLabel(for info: AXElementInfo) -> String {
        for candidate in [info.title, info.descriptionText] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        switch info.role {
        case "AXTextField": return "the text field"
        case "AXTextArea": return "the text area"
        case "AXComboBox": return "the combo box"
        case "AXSearchField": return "the search field"
        case "AXEmailField": return "the email field"
        default: return "that field"
        }
    }

    /// The field to type into: the point first, then the name, then Finder for nothing.
    ///
    /// Deliberately not `target(label:at:)`: that one only returns controls that answer to a press
    /// action, and a text field usually answers to none. Reusing it would make every field an
    /// `notPressable` refusal.
    public static func typeTarget(label: String, at point: CGPoint) -> TypeTarget? {
        guard isTrusted(), let window = window(at: point) else { return nil }
        let app = AXUIElementCreateApplication(pid_t(window.pid))
        _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)

        if let field = resolvedField(at: point, in: window, app: app, label: label) {
            return field
        }
        // Chromium and Electron — which is what WhatsApp, Slack, VS Code and every browser tab are
        // — publish an empty tree until an assistive client asks, so the first read of a field that
        // is plainly on screen finds nothing. One write to the app element turns the tree on and
        // the same two reads are retried once: without this, "type in the message box" answers "that
        // app does not expose a field" forever.
        enableManualAccessibility(on: app)
        for attempt in 0..<fieldRetries {
            if let field = resolvedField(at: point, in: window, app: app, label: label) {
                return field
            }
            // The other case is time, not permission: a search box that opens when you press it is
            // not a field yet at the instant the press returns. Measured 2026-10-05 in WhatsApp,
            // where a plan pressed the search control and the type step aimed at the same point
            // found nothing — 500 ms later the field was there.
            usleep(fieldRetryPause)
            _ = attempt
        }
        // Last, and the only route that works when the field is open but is not where the aim
        // landed: ask the app which element it considers focused.
        if let focused = focusedField(in: app, window: window, label: label) {
            return TypeTarget(element: focused, info: describe(focused, window: window),
                              snapped: true)
        }
        // And the field that exists because something was just pressed. WhatsApp's search box is
        // the measured case — the aim lands on the placeholder's text node, which is not a field
        // and never will be, while the real input sits open elsewhere in the same window. If the
        // window holds exactly one visible field, that is the one the user meant; two is a
        // question, not a guess.
        if let sole = soleEditable(in: app, window: window) {
            return TypeTarget(element: sole, info: describe(sole, window: window), snapped: true)
        }
        if focusIsUnanswerable(in: app, window: window), let hit = elementAtPosition(in: window, point)
            ?? searchedElement(in: app, window: window, label: label) {
            return TypeTarget(element: hit, info: describe(hit, window: window),
                              snapped: true, viaFirstResponder: true)
        }
        return nil
    }

    /// The only visible text field in a window, if there is exactly one.
    ///
    /// "Exactly one" is the whole safety of this route. A chat window with its search open has one
    /// field and the intent is unambiguous; a form with six has six, and typing into the first one
    /// the walk reaches is a guess the user never agreed to. The search is bounded by the same
    /// budget as every other walk, and stops early the moment a second candidate appears.
    private static func soleEditable(in app: AXUIElement, window: WindowRecord) -> AXUIElement? {
        var found: AXUIElement?
        var visited = 0
        var queue: [AXUIElement] = [searchRoot(in: app, matching: window, hit: nil)]
        while !queue.isEmpty, visited < maxNameSearchElements {
            let element = queue.removeFirst()
            visited += 1
            if isEditable(element),
               isOnScreen(frame(of: element), in: window) {
                if found != nil { return nil }
                found = element
            }
            queue.append(contentsOf: children(of: element))
        }
        return found
    }

    /// Whether this app's answer to "what has focus?" is useless.
    ///
    /// Catalyst apps answer with a content group the size of the window (measured on WhatsApp:
    /// `AXGroup/iOSContentGroup` at (0, 34) 1710x1073), and an app that names the whole window as
    /// its focused element is not telling us anything a person could check.
    static func focusIsUnanswerable(role: String?, subrole: String?, frame: CGRect?,
                                    window: WindowRecord) -> Bool {
        if subrole == "iOSContentGroup" { return true }
        guard let role, ["AXGroup", "AXWindow", "AXUnknown"].contains(role) else { return false }
        guard let frame else { return true }
        return frame.width * frame.height > window.bounds.width * window.bounds.height * 0.85
    }

    private static func focusIsUnanswerable(in app: AXUIElement, window: WindowRecord) -> Bool {
        guard let focused = copyAttribute(app, kAXFocusedUIElementAttribute as String)
                .map({ $0 as! AXUIElement }) else { return true }
        return focusIsUnanswerable(role: stringAttribute(focused, kAXRoleAttribute as String),
                                   subrole: stringAttribute(focused, kAXSubroleAttribute as String),
                                   frame: frame(of: focused), window: window)
    }

    /// The element in the window whose name answers `label`, whatever its role.
    private static func searchedElement(in app: AXUIElement, window: WindowRecord,
                                        label: String) -> AXUIElement? {
        var visited = 0
        var queue: [AXUIElement] = [searchRoot(in: app, matching: window, hit: nil)]
        while !queue.isEmpty, visited < maxNameSearchElements {
            let element = queue.removeFirst()
            visited += 1
            let name = stringAttribute(element, kAXTitleAttribute as String)
                ?? stringAttribute(element, kAXDescriptionAttribute as String)
                ?? stringAttribute(element, kAXPlaceholderValueAttribute as String) ?? ""
            if !name.isEmpty, nameScore(label: label, title: name) >= 2,
               isOnScreen(frame(of: element), in: window) {
                return element
            }
            queue.append(contentsOf: children(of: element))
        }
        return nil
    }

    /// The field the app itself says has focus, when that is a field the user could have meant.
    ///
    /// Measured 2026-10-05 on WhatsApp: a plan pressed the search control, the search bar visibly
    /// opened and took focus, and the type step still found no editable element at the point it was
    /// aimed at — the aim landed on the placeholder's text node, which is not the field. Chunks
    /// already refuses to post a character unless its target *is* the focused element, so a
    /// focused editable element is the strongest evidence there is about where the words would go.
    ///
    /// It still has to answer to the name the user used, and still has to be inside the window the
    /// aim landed in: focus somewhere else on the machine is not a licence to type there.
    private static func focusedField(in app: AXUIElement, window: WindowRecord,
                                     label: String) -> AXUIElement? {
        guard let focused = copyAttribute(app, kAXFocusedUIElementAttribute as String)
                .map({ $0 as! AXUIElement }),
              isEditable(focused),
              let frame = frame(of: focused), isOnScreen(frame, in: window)
        else { return nil }
        let name = stringAttribute(focused, kAXTitleAttribute as String)
            ?? stringAttribute(focused, kAXDescriptionAttribute as String)
            ?? stringAttribute(focused, kAXPlaceholderValueAttribute as String) ?? ""
        guard name.isEmpty || nameScore(label: label, title: name) >= 1 else { return nil }
        return focused
    }

    /// How many times to look for a field that is not published yet, and how long to wait between.
    static let fieldRetries = 3
    static let fieldRetryPause: useconds_t = 350_000

    /// The point first, the name second, packaged with the metadata the card needs.
    private static func resolvedField(at point: CGPoint, in window: WindowRecord,
                                      app: AXUIElement, label: String) -> TypeTarget? {
        let hit = elementAtPosition(in: window, point)
        if let found = editable(from: hit) {
            return TypeTarget(element: found, info: describe(found, window: window),
                              snapped: false)
        }
        guard let found = searchedField(in: app, window: window, hit: hit,
                                        label: label, near: point)
        else { return nil }
        return TypeTarget(element: found, info: describe(found, window: window), snapped: true)
    }

    /// The editable element a point's hit landed on, or the nearest ancestor that holds text.
    private static func editable(from hit: AXUIElement?) -> AXUIElement? {
        guard let hit else { return nil }
        if isEditable(hit) { return hit }
        var current = hit
        var walked = 0
        while walked < maxAncestorWalk, let parent = parent(of: current) {
            current = parent
            walked += 1
            if isEditable(current) {
                return current
            }
        }
        return nil
    }

    private static func searchedField(in app: AXUIElement, window: WindowRecord,
                                      hit: AXUIElement?, label: String,
                                      near point: CGPoint) -> AXUIElement? {
        searchForEditable(in: searchRoot(in: app, matching: window, hit: hit),
                          label: label, near: point)
    }

    /// Ask an app to publish its accessibility tree. Returns whether the app accepted the write.
    private static func enableManualAccessibility(on app: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            == .success
    }

    /// The editable element in a subtree whose name answers `label`.
    ///
    /// The same walk budget as the press search, because the same wrong guess about a huge page is
    /// possible here.
    private static func searchForEditable(in root: AXUIElement, label: String,
                                          near point: CGPoint) -> AXUIElement? {
        var fields: [(element: AXUIElement, match: NamedElementMatch)] = []
        var visited = 0
        var queue: [AXUIElement] = [root]

        while !queue.isEmpty, visited < maxNameSearchElements {
            let element = queue.removeFirst()
            visited += 1
            if isEditable(element) {
                let name = stringAttribute(element, kAXTitleAttribute as String)
                    ?? stringAttribute(element, kAXPlaceholderValueAttribute as String)
                    ?? stringAttribute(element, kAXDescriptionAttribute as String) ?? ""
                fields.append((element, NamedElementMatch(title: name,
                                                          frame: frame(of: element))))
            }
            queue.append(contentsOf: children(of: element))
        }

        // A field with no name is still the field, if it is the only one: "type it in the message
        // box" in an app with one input is not ambiguous. With several, an unnamed one cannot be
        // picked out by a name that matches nothing.
        if let only = fields.first, only.match.title.isEmpty, fields.count == 1 {
            return only.element
        }
        let named = fields.filter { !$0.match.title.isEmpty }
        guard let index = bestMatch(label: label, candidates: named.map(\.match),
                                    near: point) else { return nil }
        return named[index].element
    }

    /// Type into a field that has already been resolved and approved.
    ///
    /// The text goes in as keyboard events, not as a value write. `AXUIElementSetAttributeValue`
    /// would be one call and would look cleaner in the diff, and it would leave half the apps on
    /// the screen holding text their own logic never saw: no `input` event, no autocomplete, no
    /// "the send button is now enabled". Posting the characters is what the Auto Typer script this
    /// feature was modelled on does, and it is what the user's own hands do.
    ///
    /// Nothing here moves the pointer, so invariant 8's ban on synthetic mouse events stands.
    public static func type(_ text: String, into target: TypeTarget) -> TypeResult {
        guard isTrusted() else { return .permissionMissing }
        // The rule is that keystrokes land wherever the cursor is, so the field the user approved
        // has to *be* the focused element. The exception is an app that cannot say what it has
        // focused — see `TypeTarget.viaFirstResponder`, which is only set after `focusIsUnanswerable`
        // proved the app names its whole window. There, insisting would mean never typing into
        // Catalyst at all, and the keystrokes still go to UIKit's own first responder.
        if target.viaFirstResponder {
            post(text)
            // No witness exists here by construction — the app cannot name its own cursor — so the
            // report must say posted-and-unconfirmed, not typed (AUDIT.md A-05).
            return .postedUnverified(appName: target.info.appName, characters: text.count)
        }
        // `focusedFieldMatches` is the escape hatch for an app that cannot name its own cursor.
        // WhatsApp answers `AXFocusedUIElement` with a content group the size of the window, so
        // the exact-element test can never pass there — and a gate that nothing can satisfy
        // protects nothing; it only refuses work the user already approved.
        guard hasFocus(target.element) || takeFocus(on: target.element)
                || focusedFieldMatches(target) else {
            return .focusRefused(element: target.info)
        }
        // Read again after asking: an app can accept the focus write and put the cursor elsewhere,
        // and typing into wherever the cursor actually is not the act the user approved. The hatch
        // apps answer with a content group, so for them the weaker question is the only one that
        // can ever pass — insisting on the exact element here made the hatch unreachable and
        // refused every named type into Catalyst (AUDIT.md A-06).
        guard hasFocus(target.element) || focusedFieldMatches(target) else {
            return .focusRefused(element: target.info)
        }
        switch Self.newlinePolicy(text: text, role: target.info.role) {
        case .refused(let lineBreaks):
            return .multilineIntoSingleLine(element: target.info, lineBreaks: lineBreaks)
        case .ok: break
        }

        post(text)
        // A web editor applies keystrokes on its own clock: reading the field back in the same
        // instant as posting a few thousand characters can catch it mid-update, and "the field
        // refused the text" about a lag that clears a moment later is a lie about an act that
        // landed. The waits are paid only when the first read does not yet match.
        //
        // Three outcomes, and the middle one is the 2026-10-30 fix. A Chromium `AXTextArea` answers
        // `kAXValueAttribute` with an **empty string** — not nil, not an error — even when the caret
        // took every keystroke. An empty value is *no witness*, so the honest report is the one
        // `typeWeb` already gives. A value that came back with words in it and still does not
        // contain the payload is a real contradiction, and keeps refusing.
        var last: TypeWitness = .silent
        for attempt in 0..<readbackAttempts {
            last = Self.witness(value: stringAttribute(target.element, kAXValueAttribute as String),
                                payload: text)
            switch last {
            case .confirmed:
                return .typed(element: target.info, characters: text.count)
            case .silent:
                // A field that will not speak at all is still a field that was focused and fed.
                if attempt == 0 { break }
            case .contradicts:
                break
            }
            if attempt < readbackAttempts - 1 { usleep(readbackPauseMicroseconds) }
        }
        switch last {
        case .confirmed:
            return .typed(element: target.info, characters: text.count)
        case .silent:
            return .postedUnverified(appName: target.info.appName, characters: text.count)
        case .contradicts:
            // A web-hosted field is held to `typeWeb`'s standard, not the native one. The focus
            // check above is the gate — it proved the caret was in the element he approved — and a
            // Chromium editor's value is a viewport, not a document: CodeMirror answers with the
            // lines on screen, so text that landed below the fold reads as a contradiction. The
            // 2026-10-30 log shows exactly that: the same name resolving to a textarea whose frame
            // walked from (773,174) to (743,127) as the caret moved, confirming once and "refusing"
            // every time after. Native apps keep refusing, because there the value is the truth.
            if Self.isWebHosted(target.element) {
                return .postedUnverified(appName: target.info.appName, characters: text.count)
            }
            return .rejectedByField(element: target.info)
        }
    }

    /// Whether an element lives inside a web area, found by climbing its ancestors.
    ///
    /// Bounded because this runs on the type path, where a huge page tree must not be walked to
    /// decide a wording. Twenty levels reaches the `AXWebArea` of any real document and stops well
    /// short of the cost the name search already caps.
    public static func isWebHosted(_ element: AXUIElement, limit: Int = 20) -> Bool {
        var current = element
        for _ in 0..<limit {
            if stringAttribute(current, kAXRoleAttribute as String) == "AXWebArea" { return true }
            guard let parent = parent(of: current) else { return false }
            current = parent
        }
        return false
    }

    /// What a field's read-back value actually says about the payload it was just given.
    ///
    /// Pulled out of `type` because the distinction it draws is the whole bug class, and it cannot
    /// be tested while it is welded to a live `AXUIElement`. `silent` and `contradicts` used to be
    /// the same answer, and the one that was wrong every time was the one a Chromium editor gave.
    public enum TypeWitness: Equatable, Sendable {
        case confirmed
        /// The attribute was absent, or came back with nothing but whitespace in it.
        case silent
        /// Words came back, and the payload is not among them.
        case contradicts
    }

    public static func witness(value: String?, payload: String) -> TypeWitness {
        guard let value else { return .silent }
        if value.contains(payload) || allLinesPresent(value: value, payload: payload)
            || mostPayloadLinesPresent(value: value, payload: payload) {
            return .confirmed
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .silent : .contradicts
    }

    static let readbackAttempts = 4
    static let readbackPauseMicroseconds: useconds_t = 120_000

    /// Post a real mouse click at a point. The pointer moves there first, because WindowServer
    /// hit-tests wherever the hardware cursor is and no event location can fake that.
    ///
    /// This is the door into web content that publishes no Accessibility verb: measured 2026-10-29 on
    /// a live Chrome quiz, three aims in a row answered `nothing pressable at … role=AXGroup` — the
    /// option is a `div` with a click handler, and there is no `AXPress` to perform on it. Chunks'
    /// standing rule is to press through Accessibility and never move the pointer, and the rule still
    /// holds wherever the app publishes a verb; this path exists for the surface that publishes none,
    /// which the user asked for out loud on 2026-10-29. The pause before the click is the one his own
    /// typer waits after a click: the receiving app needs the cursor to have landed.
    public static func click(at point: CGPoint) -> Bool {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        usleep(50_000)
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        var posted = 0
        for kind in [CGEventType.leftMouseDown, .leftMouseUp] {
            if let event = CGEvent(mouseEventSource: source, mouseType: kind,
                                   mouseCursorPosition: point, mouseButton: .left) {
                event.post(tap: .cghidEventTap)
                posted += 1
            }
        }
        return posted == 2
    }

    /// Post `text` as keyboard events: Unicode pairs for characters, real key presses for the
    /// control characters that have no Unicode delivery.
    ///
    /// Chunked with a yield between chunks: a tight loop of a few thousand events outruns the
    /// receiving app's own event queue — a web editor drops keystrokes it has not processed yet,
    /// and the loss is silent. The pause is paid only past the first chunk, so a short message
    /// types exactly as fast as it always did.
    private static func post(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        var posted = 0
        for character in text {
            if character == "\n" {
                // A Unicode line feed is swallowed by web editors — photographed on Programiz,
                // where a whole C file arrived on line one. His typer presses Return between
                // lines because `write` cannot deliver a newline any other way. Same key, same
                // tap; the newline policy has already proved this field is multiline, so a
                // Return here is a newline and cannot be a Send.
                postKey(virtualKeyReturn, source)
            } else {
                var units = Array(String(character).utf16)
                if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                    down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                    down.post(tap: .cghidEventTap)
                }
                CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)?
                    .post(tap: .cghidEventTap)
            }
            posted += 1
            // A visible cadence for a sentence: the events used to go in as fast as the machine can
            // post them, so a short message appeared in the field all at once and read like a paste.
            // He asked to watch it type. A whole file is the exception — 6,000 characters at this rate
            // is a minute of nothing happening, and nobody is watching for the pleasure of it.
            if text.count <= visibleTypingCharacters { usleep(keystrokeCadenceMicroseconds) }
            if posted % postChunkCharacters == 0 { usleep(postChunkPauseMicroseconds) }
        }
    }

    /// Microseconds between keystrokes while the payload is short enough to watch.
    static let keystrokeCadenceMicroseconds: UInt32 = 9_000
    /// Above this many characters the cadence stops, and the chunked fast path is used.
    static let visibleTypingCharacters = 240

    /// One physical key, down and up — the shape `write` cannot fake for control characters.
    private static func postKey(_ virtualKey: CGKeyCode, _ source: CGEventSource) {
        CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)?
            .post(tap: .cghidEventTap)
    }

    /// `kVK_Return`.
    static let virtualKeyReturn: CGKeyCode = 36

    /// How many keystrokes go out before the receiving app gets a breath.
    static let postChunkCharacters = 100
    static let postChunkPauseMicroseconds: useconds_t = 8_000

    /// Whether the point sits in web content that publishes no field of its own.
    ///
    /// A Chromium editor holds no `AXTextArea` until the caret is in it, and holds no pressable
    /// control at all — which is why a plan that "presses the editor to focus it" stops dead on a
    /// correct refusal. This is the signature that says the caret, not a control, is what is missing.
    public static func webEditorCandidate(at point: CGPoint) -> Bool {
        guard let info = elementAt(point) else { return false }
        let role = info.role ?? ""
        return !editableRoles.contains(role)
            && (role == "AXGroup" || role == "AXWebArea" || role == "AXDiv" || role.isEmpty)
    }

    /// Put the caret where the aim is: one click at the box, then the breath his proven Auto Typer
    /// waits before the first keystroke.
    ///
    /// A synthetic mouse click, which invariant 8 keeps away from *presses* — a press has an
    /// Accessibility verb and a click has a pointer jump the user watches. A caret has no verb at
    /// all in web content, the jump is the whole effect, and the card names it before it happens,
    /// so this is the one place the click is the act rather than a shortcut around one.
    static func focusClick(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for isDown in [true, false] {
            guard let event = CGEvent(mouseEventSource: source,
                                      mouseType: isDown ? .leftMouseDown : .leftMouseUp,
                                      mouseCursorPosition: point,
                                      mouseButton: .left) else { continue }
            event.post(tap: .cghidEventTap)
        }
        usleep(focusClickPauseMicroseconds)
    }

    static let focusClickPauseMicroseconds: useconds_t = 50_000

    /// Type into web content the way his proven Auto Typer does: click the caret in, post the
    /// keystrokes, and ask Accessibility afterwards only as a witness — never as a gate.
    ///
    /// The witness can confirm (the focused element's own value holds the text), can name a role
    /// for the newline rule, or can say nothing at all; each is reported as itself. What it is not
    /// is a precondition: an editor that answers nothing still gets the keystrokes, because the
    /// click put the caret where he approved — which is the whole contract his script proves.
    public static func typeWeb(_ text: String, at point: CGPoint) -> TypeResult {
        guard isTrusted() else { return .permissionMissing }
        guard let window = window(at: point) else { return .noField(containing: point) }
        focusClick(at: point)
        let app = AXUIElementCreateApplication(pid_t(window.pid))
        _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let witness = copyAttribute(app, kAXFocusedUIElementAttribute as String)
            .map { $0 as! AXUIElement }
        let role = witness.flatMap { stringAttribute($0, kAXRoleAttribute as String) }
        let appName = window.ownerName
        if text.contains("\n") {
            switch newlinePolicy(text: text, role: role) {
            case .refused(let breaks) where role == nil:
                return .multilineWithoutWitness(appName: appName, lineBreaks: breaks)
            case .refused(let breaks):
                return .multilineIntoSingleLine(element: describe(witness!, window: window),
                                                lineBreaks: breaks)
            case .ok: break
            }
        }
        post(text)
        guard let witness else {
            return .postedUnverified(appName: appName, characters: text.count)
        }
        for attempt in 0..<readbackAttempts {
            guard let value = stringAttribute(witness, kAXValueAttribute as String) else { break }
            if value.contains(text) || Self.allLinesPresent(value: value, payload: text)
                || Self.mostPayloadLinesPresent(value: value, payload: text) {
                return .typed(element: describe(witness, window: window),
                              characters: text.count)
            }
            if attempt < readbackAttempts - 1 { usleep(readbackPauseMicroseconds) }
        }
        return .postedUnverified(appName: appName, characters: text.count)
    }

    /// Whether every line of the payload appears in the field's value, allowing the editor to
    /// have re-indented lines as they arrived.
    ///
    /// CodeMirror indents on Enter, so the value of a successfully typed file carries more leading
    /// whitespace than the payload did; a strict `contains` would report that act as refused,
    /// which is the lie this helper exists to prevent.
    static func allLinesPresent(value: String, payload: String) -> Bool {
        let lines = payload.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty else { return true }
        return lines.allSatisfy { !$0.isEmpty && value.contains($0) }
    }

    /// Whether the field's value shows a meaningful share of the payload's longer lines.
    ///
    /// CodeMirror's accessibility value carries the visible viewport, not the whole document —
    /// photographed 22:00 on Programiz, where 31 lines had landed correctly and the read-back
    /// could see ten, so a successful type reported itself refused. "None of the code is here"
    /// and "not all of it is on screen" are different claims; this tells them apart so the
    /// witness never contradicts the screen the user is looking at.
    static func mostPayloadLinesPresent(value: String, payload: String) -> Bool {
        let lines = payload.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 10 }
        guard !lines.isEmpty else { return allLinesPresent(value: value, payload: payload) }
        let matched = lines.reduce(0) { $0 + (value.contains($1) ? 1 : 0) }
        return matched * 2 >= lines.count
    }

    private static func takeFocus(on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            == .success
    }

    /// Whether the app's own focus answer names *a* field in the target's app.
    ///
    /// Deliberately weaker than "is this exact element", and only used when the exact test fails:
    /// an app that reports a content group as its focused element cannot be checked any harder
    /// than this, and refusing forever is what made WhatsApp's search box untypeable.
    private static func focusedFieldMatches(_ target: TypeTarget) -> Bool {
        var pid = pid_t(0)
        guard AXUIElementGetPid(target.element, &pid) == .success else { return false }
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let focused = copyAttribute(app, kAXFocusedUIElementAttribute as String)
                .map({ $0 as! AXUIElement }) else { return false }
        return isEditable(focused)
    }

    /// Whether `element` is the control the app itself calls focused.
    ///
    /// Public for `--probe-ax`, which can otherwise not tell a user why a field they can see would
    /// be refused: the resolution succeeding and the cursor being elsewhere are two different lines.
    public static func hasFocus(_ element: AXUIElement) -> Bool {
        var pid = pid_t(0)
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let focused = copyAttribute(app, kAXFocusedUIElementAttribute as String)
        else { return false }
        return CFEqual(focused as! AXUIElement, element)
    }

    // MARK: Scrolling a list or a page

    /// The action that moves a scrollable element one page, per direction.
    static let pageScrollActions: [ActionRequest.ScrollDirection: String] = [
        .down: "AXScrollDownByPage", .up: "AXScrollUpByPage",
        .left: "AXScrollLeftByPage", .right: "AXScrollRightByPage",
    ]

    /// The fallback for the many controls that implement the generic stepper verbs and none of
    /// the page ones — a scroll bar in a native app, a table in a settings pane.
    static let lineScrollActions: [ActionRequest.ScrollDirection: String] = [
        .down: "AXDecrement", .up: "AXIncrement", .left: "AXDecrement", .right: "AXIncrement",
    ]

    /// How many line steps stand in for one page when only the stepper verbs exist.
    static let linesPerPage = 6

    /// Pause between repeated steps of one scroll act.
    ///
    /// Apps coalesce scroll updates into their next layout pass, and a tight loop of ten
    /// `AXDecrement` calls inside one run loop turn moves the view by one.
    static let scrollStepPause: useconds_t = 60_000

    /// A scrollable element, and the verb on it that moves the way the user asked.
    public struct ScrollTarget {
        public var element: AXUIElement
        public var info: AXElementInfo
        public var action: String
        /// Whether `action` moves a whole page; a line verb is repeated `linesPerPage` times per
        /// page instead, and the card's sentence is the same either way.
        public var movesPages: Bool
        /// Whether the aim landed on the scroller or the scroller had to be searched for.
        public var snapped: Bool

        public init(element: AXUIElement, info: AXElementInfo, action: String,
                    movesPages: Bool, snapped: Bool) {
            self.element = element
            self.info = info
            self.action = action
            self.movesPages = movesPages
            self.snapped = snapped
        }
    }

    public enum ScrollResult: Equatable, Sendable {
        case scrolled(element: AXElementInfo, direction: ActionRequest.ScrollDirection,
                      pages: Int, action: String)
        case permissionMissing
        /// Nothing on the way up from that point moves.
        case noScrollableElement(containing: CGPoint)
        /// The scroller was found and refused the verb.
        case refusedByElement(element: AXElementInfo, action: String, code: Int)

        public var didScroll: Bool {
            if case .scrolled = self { return true }
            return false
        }

        /// The line on the card, and the sentence that gets read out.
        ///
        /// Only `.scrolled` may use the past tense. A scroll that was refused has to say nothing
        /// moved, because the model's own words will already have promised "scrolling down".
        public var userFacingReason: String {
            switch self {
            case .scrolled(let element, let direction, let pages, _):
                let distance = pages == 1 ? "a page" : "\(pages) pages"
                return "Scrolled \(element.elementLabel) \(direction.phrase) by \(distance)."
            case .permissionMissing:
                return "Chunks needs Accessibility access to scroll anything. Grant it, then Restart."
            case .noScrollableElement:
                return "There is no scrollable list there that Chunks can see, so nothing moved."
            case .refusedByElement(let element, let action, let code):
                return "\(element.appName ?? "That app") would not scroll "
                    + "\(element.elementLabel) (\(action) → \(AXTDriver.errorCodeName(code)), "
                    + "code \(code)), so nothing moved."
            }
        }
    }

    /// The verb to use for a direction, from the actions one element advertises.
    ///
    /// Page before line, because `AXScrollDownByPage` is what "scroll down" means to a person
    /// reading a list, and a stepper verb on the same element may be a value control that changes
    /// something rather than moving the view.
    static func scrollAction(for direction: ActionRequest.ScrollDirection,
                             advertisedIn names: [String]) -> (action: String, movesPages: Bool)? {
        if let page = pageScrollActions[direction], names.contains(page) {
            return (page, true)
        }
        if let line = lineScrollActions[direction], names.contains(line) {
            return (line, false)
        }
        return nil
    }

    /// The element that moves when the user asks to scroll at that point.
    ///
    /// A scroll area is almost never what a point hits: the aim lands on a row, a cell, or a text
    /// node, and the scroller is two or three ancestors up. So this climbs first — the same shape
    /// as the press walk — and only searches the window's subtree if the climb finds nothing.
    public static func scrollTarget(direction: ActionRequest.ScrollDirection, label: String,
                                    at point: CGPoint) -> ScrollTarget? {
        guard isTrusted(), let window = window(at: point) else { return nil }
        let app = AXUIElementCreateApplication(pid_t(window.pid))
        _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)

        let hit = elementAtPosition(in: window, point)
        if let found = scrollableAncestor(of: hit, for: direction) {
            return ScrollTarget(element: found.element,
                                info: describe(found.element, window: window),
                                action: found.action, movesPages: found.movesPages,
                                snapped: false)
        }
        let root = searchRoot(in: app, matching: window, hit: hit)
        guard let found = scrollableDescendant(in: root, for: direction) else { return nil }
        return ScrollTarget(element: found.element,
                            info: describe(found.element, window: window),
                            action: found.action, movesPages: found.movesPages,
                            snapped: true)
    }

    private static func scrollableAncestor(of hit: AXUIElement?,
                                           for direction: ActionRequest.ScrollDirection)
        -> (element: AXUIElement, action: String, movesPages: Bool)? {
        guard var current = hit else { return nil }
        var walked = 0
        var stepper: (element: AXUIElement, action: String, movesPages: Bool)?
        while true {
            if let choice = scrollAction(for: direction, advertisedIn: actionNames(on: current)) {
                if choice.movesPages { return (current, choice.action, true) }
                // A stepper is remembered but not taken yet: measured 2026-10-05 in WhatsApp, the
                // ancestors of a header point include the sidebar's `AXSplitGroup`, which answers
                // `AXDecrement` — a *resize handle*, and the nearest thing to a scroller on the way
                // up. The list the user meant is higher, or nowhere.
                stepper = stepper ?? (current, choice.action, false)
            }
            guard walked < maxAncestorWalk, let parent = parent(of: current) else { return stepper }
            current = parent
            walked += 1
        }
    }

    /// The first thing in the subtree that moves at all in that direction.
    ///
    /// Deliberately not name-matched: the user's label describes what is *in* the list, not the
    /// list, so "scroll down the chats" naming nothing would refuse a scroller that is right there.
    private static func scrollableDescendant(in root: AXUIElement,
                                             for direction: ActionRequest.ScrollDirection)
        -> (element: AXUIElement, action: String, movesPages: Bool)? {
        var visited = 0
        var queue: [AXUIElement] = [root]
        while !queue.isEmpty, visited < maxNameSearchElements {
            let element = queue.removeFirst()
            visited += 1
            if let choice = scrollAction(for: direction, advertisedIn: actionNames(on: element)) {
                return (element, choice.action, choice.movesPages)
            }
            queue.append(contentsOf: children(of: element))
        }
        return nil
    }

    /// Move a scroller the user has already been asked about (or that needs no asking).
    ///
    /// `AXUIElementPerformAction` on the element's own verb, never a synthetic wheel event:
    /// measured 2026-10-05, posting a `CGEvent` scroll moves the pointer to the event's location,
    /// and the pointer is the one thing Chunks does not touch (invariant 8).
    public static func scroll(_ direction: ActionRequest.ScrollDirection, pages: Int,
                              into target: ScrollTarget) -> ScrollResult {
        guard isTrusted() else { return .permissionMissing }
        let steps = max(1, target.movesPages ? pages : pages * linesPerPage)
        var completed = 0
        var refusal: Int?
        for step in 0..<steps {
            let code = AXUIElementPerformAction(target.element, target.action as CFString)
            guard code == .success else { refusal = Int(code.rawValue); break }
            completed += 1
            if step + 1 < steps { usleep(scrollStepPause) }
        }
        guard completed > 0 else {
            return .refusedByElement(element: target.info, action: target.action,
                                     code: refusal ?? Int(AXError.failure.rawValue))
        }
        // Report what moved, not what was asked: a scroller that refused after one page must not
        // read "Scrolled … by 3 pages" (AUDIT.md A-09).
        let reported = target.movesPages ? completed : max(1, completed / linesPerPage)
        return .scrolled(element: target.info, direction: direction, pages: reported,
                         action: target.action)
    }
}

// MARK: - Full keyboard access (TASKS.md 3.10)

extension AXTDriver {

    /// What an application says is focused, and whether it answered at all.
    ///
    /// `answered` is the field that makes this honest. Measured on this machine, an Electron editor
    /// publishes no usable tree — `--probe-fields Qoder` reads 220 elements and finds zero fields —
    /// so "I do not know where the caret is" is the normal answer for exactly the apps the keyboard
    /// feature is for, and it must never be reported as "nothing is focused".
    public struct KeyFocus: Equatable, Sendable {
        public let role: String?
        public let name: String?
        public let answered: Bool

        /// The words for the card. A role is not something to say to a person; `AXTextArea` becomes
        /// "text area", and an unnamed element is described as what it is — the focus.
        public var display: String {
            if let name, !name.isEmpty { return "\"\(name)\"" }
            if let role {
                return Self.spokenRole(role)
            }
            return answered ? "whatever has the focus" : "an app that does not say"
        }

        static func spokenRole(_ role: String) -> String {
            switch role {
            case "AXTextArea": return "the text area"
            case "AXTextField": return "the text field"
            case "AXWebArea": return "the web page"
            case "AXGroup": return "the focused area"
            default: return role.hasPrefix("AX") ? "the " + role.dropFirst(2).lowercased() : role
            }
        }
    }

    public enum KeyOutcome: Equatable, Sendable {
        case pressed(times: Int, focus: KeyFocus)
        /// The live focus makes this a different act from the one that was asked about. The card
        /// said "press return", the focus says that means Send — the same reason a press is
        /// re-resolved against the tree before it happens: an approval is about a state of the
        /// machine, and the machine moved.
        case focusChanged(reason: String, focus: KeyFocus)
        case permissionMissing
    }

    /// Read a named application's focus. Presses nothing; `--probe-keys` runs this and only this.
    public static func keyFocus(pid: Int) -> KeyFocus {
        readFocus(AXUIElementCreateApplication(CInt(pid)))
    }

    /// Post one key, the number of times asked, into the process whose pid is given.
    ///
    /// The caller — the shell, on the main actor — is the one that made sure that process is
    /// frontmost, because activation is an AppKit action and this file's rule is that the driver
    /// touches nothing main-thread-only. Keys go to the focused element of the focused application;
    /// if the wrong application is front, the wrong thing is typed, so that check is not a nicety.
    public static func keys(_ combo: KeyAction.Combo, pid: Int,
                            expected: KeyAction.Kind) -> KeyOutcome {
        guard isTrusted() else { return .permissionMissing }
        let app = AXUIElementCreateApplication(CInt(pid))
        let focus = readFocus(app)

        // Re-decide with what the app says *now*. A routine key that turns out to be a submission is
        // refused rather than performed, and the reason is the card's next sentence.
        if case .command(let reason) = KeyAction.classify(combo, focusedRole: focus.role),
           expected == .routine {
            return .focusChanged(reason: reason, focus: focus)
        }
        if case .refused(let reason) = KeyAction.classify(combo, focusedRole: focus.role) {
            return .focusChanged(reason: reason, focus: focus)
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return .focusChanged(reason: "no keyboard event source could be made", focus: focus)
        }
        // The poll that raised the app can be stale by the time the first event posts: a dialog or a
        // Space switch in between would land an asked-for combo in whatever is front (AUDIT.md A-07).
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(pid) else {
            return .focusChanged(reason: "another app took the front before the key posted",
                                 focus: focus)
        }
        let flags = CGEventFlags(rawValue: KeyAction.eventFlags(for: combo))
        for index in 0..<combo.times {
            postKey(combo.keyCode, source, flags: flags)
            // The same breath the `[TYPE:]` path gives a receiving app: a tight loop of synthetic
            // keystrokes outruns an editor's own queue and the loss is silent. Short runs keep the
            // visible cadence; a long selection is not something anyone is watching character by
            // character.
            if combo.times > 1, combo.times <= KeyAction.visibleRepeatCount,
               index < combo.times - 1 {
                usleep(keystrokeCadenceMicroseconds)
            }
        }
        return .pressed(times: combo.times, focus: focus)
    }

    private static func readFocus(_ app: AXUIElement) -> KeyFocus {
        guard let raw = copyAttribute(app, kAXFocusedUIElementAttribute as String),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return KeyFocus(role: nil, name: nil, answered: false)
        }
        let element = raw as! AXUIElement
        let role = stringAttribute(element, kAXRoleAttribute as String)
        let name = stringAttribute(element, kAXDescriptionAttribute as String)
            ?? stringAttribute(element, kAXTitleAttribute as String)
        return KeyFocus(role: role, name: name, answered: true)
    }

    /// How many repeated keystrokes still get the human-speed cadence.
    static let visibleRepeatCount = 24

    /// One physical key with its modifiers, down and up.
    ///
    /// The flags go on **both** events. Posting a keyDown with ⌘ and a keyUp without it is the shape
    /// that leaves an app believing the modifier is still held, which reads afterwards as every plain
    /// letter opening a menu.
    private static func postKey(_ virtualKey: CGKeyCode, _ source: CGEventSource,
                                flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey,
                                 keyDown: true) else { return }
        down.flags = flags
        down.post(tap: .cghidEventTap)
        guard let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey,
                               keyDown: false) else { return }
        up.flags = flags
        up.post(tap: .cghidEventTap)
    }
}
