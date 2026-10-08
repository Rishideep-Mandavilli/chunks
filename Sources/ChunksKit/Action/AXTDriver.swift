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

    /// Everything `PolicyGate` needs. `bundleID` is supplied by the caller, which has
    /// `NSRunningApplication`; this layer only knows pids.
    public func policyTarget(bundleID: String?) -> ActionTargetInfo {
        ActionTargetInfo(bundleID: bundleID, appName: appName,
                         role: role, elementLabel: elementLabel)
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
    /// apps that do list windows: the same window comes back either way.
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
                // A closed dropdown keeps its rows in the tree and addressable, so a name can
                // match something the user cannot see. `isOnScreen` is the veto.
                if score >= minScore, window == nil || isOnScreen(frame, in: window!) {
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

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
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
    private static func children(of element: AXUIElement) -> [AXUIElement] {
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

    private static func copyAttribute(_ element: AXUIElement,
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

        public var didType: Bool {
            if case .typed = self { return true }
            return false
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
            }
        }
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
            return .typed(element: target.info, characters: text.count)
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
        // and typing into wherever the cursor actually is not the act the user approved.
        guard hasFocus(target.element) else { return .focusRefused(element: target.info) }

        post(text)
        guard let value = stringAttribute(target.element, kAXValueAttribute as String) else {
            // The field will not show its contents. Focus was verified and the keys were posted, so
            // the honest report is that it happened — with the reason it could not be checked in
            // the log line the caller writes.
            return .typed(element: target.info, characters: text.count)
        }
        return value.contains(text) ? .typed(element: target.info, characters: text.count)
                                    : .rejectedByField(element: target.info)
    }

    /// Post `text` as Unicode keyboard events, one event pair per character.
    private static func post(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for character in text {
            var units = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)?
                .post(tap: .cghidEventTap)
        }
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
        return .scrolled(element: target.info, direction: direction, pages: pages,
                         action: target.action)
    }
}
