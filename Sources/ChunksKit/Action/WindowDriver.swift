import AppKit
import ApplicationServices
import Foundation

/// The machine half of a window verb: what is on the screen, and what one act did to it.
///
/// `WindowAct` decides what a sentence *means*; this reads the machine and performs. The split is the
/// same one `PolicyGate`/`AXTDriver` use, and for the same reason — the part with the negative cases is
/// pure and testable, and the part that touches Accessibility is the part that has to be watched on a
/// real screen.
///
/// Nothing here moves the cursor. `kAXRaiseAction`, setting `AXMinimized`, pressing a window's own
/// close button and `NSRunningApplication.terminate()` are all acts on elements, which is invariant 8's
/// requirement, and it is why a synthetic mouse event is not the shortcut it looks like.
public enum WindowDriver {

    /// How many windows one app may contribute, and how many in total.
    ///
    /// The same argument as `maxNameSearchElements`: a walk with no bound is a notch that sits frozen
    /// mid-turn, and the app most likely to have a hundred windows is a browser, which is also the app
    /// whose titles are longest. A cap that stops early is a refusal he can hear; a cap that does not
    /// exist is a hang he cannot.
    public static let maxWindowsPerApp = 25
    public static let maxWindowsTotal = 150

    /// Every window Chunks can see, with titles. Read-only: nothing is raised, minimised or closed.
    ///
    /// Titles come from Accessibility rather than `CGWindowListCopyWindowInfo`, for two measured
    /// reasons in this codebase: the window list stops listing the desktop the moment another app
    /// covers it, and an app that answers `AXWindows` with nothing at all (WhatsApp) still has a
    /// frontmost window worth naming.
    ///
    /// **But Accessibility alone was measured to be a lie about the question this feature exists to
    /// answer.** Measured 2026-11-03 on his Mac, with Qoder covering the display: eight regular apps
    /// were running, and `kAXWindowsAttribute` returned an *empty array* for six of them — including
    /// Google Chrome, which the window server still listed with the named windows "GVPCE" and
    /// "API keys | Google AI Studio". An app whose windows are all on another Space or minimised
    /// publishes none, so a listing built only on Accessibility answered "you have two windows open"
    /// to a man with eight apps and said `0 left out` while doing it. That is the exact failure
    /// `list_windows` was written to prevent: the whole promise was "a window on another Space,
    /// minimised, or behind the front one".
    ///
    /// So the read is a union, and the two sources are kept apart by `isReachable`. Accessibility
    /// gives a window an *element*, which is what every verb needs; the window server gives a title
    /// and a rectangle and nothing to act on. A window only the server knows about is therefore
    /// listed honestly and refused specifically, never silently dropped and never offered a card whose
    /// Allow would lead to nothing.
    public static func candidates(appNamed name: String? = nil) -> [WindowAct.Candidate] {
        let server = serverWindows()
        // A window whose frame is the whole of a display and which has no title of its own is Finder's
        // desktop. Both facts together are the test: a full-screen app's window is the same size but
        // always carries a title, and refusing that would refuse real windows he does want moved.
        let wholeDisplays = surfaces().map(\.globalFrame)
        var out: [WindowAct.Candidate] = []
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for app in apps {
            if let name, !AXTDriver.matchesAppName(label: name, owner: app.localizedName ?? "") {
                continue
            }
            guard out.count < maxWindowsTotal else { break }
            let pid = Int(app.processIdentifier)
            let element = AXUIElementCreateApplication(app.processIdentifier)
            let focused = AXTDriver.copyAttribute(element, kAXFocusedWindowAttribute as String)
            let appName = app.localizedName ?? ""
            var seen = 0
            var fromAccessibility: [WindowAct.Candidate] = []
            for window in windows(of: element) {
                guard seen < maxWindowsPerApp, out.count < maxWindowsTotal else { break }
                seen += 1
                let frame = frame(of: window)
                // The same floor as the server's own list, and for the same measured reason. Photographed
                // 2026-11-03: Chrome publishes three "windows" through Accessibility, two of them
                // `AXUnknown` at 1710x41 and 1710x81 with no title — its toolbar and tab strip. They made
                // `close Chrome` refuse with "3 windows answer that name" about one document. A strip of
                // chrome is not a window a person means, and counting one is how an honest refusal turns
                // into a wrong one.
                guard frame.width >= minListedWidth, frame.height >= minListedHeight else { continue }
                let ownTitle = AXTDriver.stringAttribute(window, kAXTitleAttribute as String)
                let candidate = WindowAct.Candidate(
                    pid: pid,
                    appName: appName,
                    title: ownTitle
                        ?? AXTDriver.stringAttribute(window, kAXDescriptionAttribute as String) ?? "",
                    frame: frame,
                    isMinimized: boolAttribute(window, kAXMinimizedAttribute as String),
                    isFocused: focused != nil && CFEqual(focused as CFTypeRef, window as CFTypeRef),
                    isDesktop: (ownTitle ?? "").isEmpty && wholeDisplays.contains(frame))
                fromAccessibility.append(candidate)
                out.append(candidate)
            }
            for window in server where window.pid == pid {
                guard out.count < maxWindowsTotal,
                      window.frame.width >= minListedWidth, window.frame.height >= minListedHeight,
                      // A window the server will not name is not a window a person means. Measured
                      // 2026-11-03: every app on his Mac carries an untitled 500x500 surface at
                      // (0, 607) — a screen-capture or sharing layer, not a document — and a listing of
                      // those reads as "you have eighteen windows open" about six. Accessibility names
                      // its own windows through `AXDescription` as well as `AXTitle`, so this only
                      // trims the server's contribution.
                      !window.title.isEmpty
                else { continue }
                // Same rectangle or same title, same window: the two sources agree often enough that
                // listing both would show him "Chrome (4)" for two tabs.
                if fromAccessibility.contains(where: { $0.frame == window.frame }) { continue }
                if fromAccessibility.contains(where: { $0.title == window.title }) { continue }
                out.append(WindowAct.Candidate(pid: pid, appName: appName, title: window.title,
                                               frame: window.frame, isMinimized: false,
                                               isFocused: false, isReachable: false))
            }
        }
        return out
    }

    /// The smallest thing either source will be believed to have drawn.
    ///
    /// Measured on his Mac: the server lists layer-0 windows at `1710x34` and `64x64` with no title at
    /// all — shadows, tooltips, the menu-bar strip. A listing of those is worse than no listing, because
    /// "you have eleven windows" about eleven pieces of chrome is a number he cannot use.
    public static let minListedWidth: CGFloat = 200
    public static let minListedHeight: CGFloat = 120

    /// One window the window server knows about.
    struct ServerWindow {
        let pid: Int
        let title: String
        let frame: CGRect
    }

    /// The window server's own list: layer-0 windows, titled or not, on any Space.
    ///
    /// Coordinates are **global display points, top-left origin** — the same space Accessibility
    /// reports in, which is why a frame from here can be compared with a frame from there without a
    /// conversion. Invariant 1 is the reason that sentence needs saying out loud: `CGWindowList` bounds
    /// are *not* `NSWindow` frames and *not* device pixels, and the first code that moves a window from
    /// here has to go through `CoordinateSpace` like everything else.
    static func serverWindows() -> [ServerWindow] {
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var out: [ServerWindow] = []
        for entry in all {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int,
                  let alpha = entry[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double
            else { continue }
            out.append(ServerWindow(pid: pid,
                                    title: (entry[kCGWindowName as String] as? String) ?? "",
                                    frame: CGRect(x: x, y: y, width: width, height: height)))
        }
        return out
    }

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        guard let raw = AXTDriver.copyAttribute(app, kAXWindowsAttribute as String) as? [AnyObject]
        else { return [] }
        return raw.map { $0 as! AXUIElement }
    }

    /// A window's rectangle in **AX space: global logical points, top-left origin**.
    ///
    /// Not an `NSWindow` frame and not device pixels. Nothing in this slice maps it anywhere, and the
    /// first verb that does has to go through `CoordinateSpace` — see the note on
    /// `WindowAct.Candidate.frame`.
    static func frame(of window: AXUIElement) -> CGRect {
        guard let positionValue = AXTDriver.copyAttribute(window, kAXPositionAttribute as String),
              let sizeValue = AXTDriver.copyAttribute(window, kAXSizeAttribute as String)
        else { return .zero }
        var origin = CGPoint.zero
        var size = CGSize.zero
        // The casts are the bridge AX's own API asks for: these attributes are `AXValue`s by contract,
        // and a failed `AXValueGetValue` leaves the zero rect rather than a plausible wrong one.
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return .zero }
        return CGRect(origin: origin, size: size)
    }

    static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool {
        guard let value = AXTDriver.copyAttribute(element, name) else { return false }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    /// The window element a candidate names, found again rather than trusted.
    ///
    /// The same re-read a press does before it lands: a card can outlive a relayout, and acting on
    /// whatever now occupies that title is not what he approved. Matching on title *and* frame means a
    /// window that moved while the card was open is a refusal, not a different act.
    public static func element(for candidate: WindowAct.Candidate) -> AXUIElement? {
        let element = AXUIElementCreateApplication(pid_t(candidate.pid))
        return windows(of: element).first { window in
            let title = AXTDriver.stringAttribute(window, kAXTitleAttribute as String)
                ?? AXTDriver.stringAttribute(window, kAXDescriptionAttribute as String) ?? ""
            return title == candidate.title && frame(of: window) == candidate.frame
        }
    }

    public static func focus(_ candidate: WindowAct.Candidate) -> Bool {
        guard let window = element(for: candidate) else { return false }
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
        // Raising a window inside a background app leaves it behind everything else, so the app is
        // activated too — that is what "bring to the front" means to a person.
        NSRunningApplication(processIdentifier: pid_t(candidate.pid))?
            .activate(options: [.activateIgnoringOtherApps])
        return raised
    }

    public static func minimize(_ candidate: WindowAct.Candidate) -> Bool {
        guard let window = element(for: candidate) else { return false }
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                            kCFBooleanTrue) == .success
    }

    /// Close a window by pressing its own close button.
    ///
    /// There is no `AXClose` verb, and the alternative — synthesising a click on the traffic light —
    /// would move the cursor, which is the one thing this app does not do. A window that publishes no
    /// close button is a refusal: guessing at some other button in the title bar is how a document gets
    /// something else done to it.
    public static func close(_ candidate: WindowAct.Candidate) -> Bool {
        guard let window = element(for: candidate), let button = closeButton(of: window)
        else { return false }
        // A plain `AXPress` on the window's own button: no verb list to walk, because a traffic light
        // publishes exactly one, and no synthetic click, because that would move the cursor.
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    static func closeButton(of window: AXUIElement) -> AXUIElement? {
        AXTDriver.children(of: window).first { child in
            let role = AXTDriver.stringAttribute(child, kAXRoleAttribute as String)
            let subrole = AXTDriver.stringAttribute(child, kAXSubroleAttribute as String)
            return role == kAXButtonRole as String && subrole == "AXCloseButton"
        }
    }

    /// Quit an app gracefully, and report a refusal rather than forcing it.
    ///
    /// `terminate()` is a request: an app with an unsaved document answers it by putting up its own
    /// sheet and staying open, which is the correct behaviour and the reason the outcome line names the
    /// likely cause. `forceTerminate()` is not called anywhere in this app — killing a process that is
    /// asking him a question is the one way to lose work he cannot get back.
    public static func quit(appNamed name: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            AXTDriver.matchesAppName(label: name, owner: $0.localizedName ?? "")
        }) else { return false }
        return app.terminate()
    }

    // MARK: - Geometry

    /// The displays, in **Accessibility's own space**: global logical points, top-left origin.
    ///
    /// `CGDisplayBounds` is already that space, which is why a whole display needs no conversion here —
    /// and why this file can hand a rectangle straight to `kAXPositionAttribute`. The *usable* rect is
    /// the one place AppKit's bottom-left origin is touched, and it is touched only as a **difference
    /// inside one screen**: `frame.maxY - visible.maxY` is the menu bar's height and
    /// `visible.minY - frame.minY` is the Dock's, and a difference is the same in either orientation.
    /// That is what keeps invariant 1 honest without a flip anywhere.
    ///
    /// Main display first, and 1-based, because "display 1" has to mean the one he calls that.
    public static func surfaces() -> [WindowPlacementPolicy.Surface] {
        let mainID = CGMainDisplayID()
        var built: [WindowPlacementPolicy.Surface] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            let bounds = CGDisplayBounds(id)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let visible = screen.visibleFrame
            let topInset = screen.frame.maxY - visible.maxY
            let leftInset = visible.minX - screen.frame.minX
            let usable = CGRect(x: bounds.minX + leftInset, y: bounds.minY + topInset,
                                width: visible.width, height: visible.height)
            built.append(WindowPlacementPolicy.Surface(index: 0, name: screen.localizedName,
                                                 isMain: id == mainID,
                                                 globalFrame: bounds, usableFrame: usable))
        }
        let ordered = built.sorted { left, right in
            if left.isMain != right.isMain { return left.isMain }
            return left.globalFrame.minX < right.globalFrame.minX
        }
        // The index is assigned after ordering, so a number he says out loud is the position he sees in
        // Display Settings rather than whatever order the window server enumerated.
        return ordered.enumerated().map { pair in
            var surface = pair.element
            surface.index = pair.offset + 1
            return surface
        }
    }

    /// How close the window has to end up for the move to be reported as done.
    ///
    /// Four points, not zero: a window manager that snaps to a grid, a rounded corner radius, or a
    /// display scale of 3x all make an exact equality a coin toss, and a tolerance that is too wide
    /// would call a move that did nothing a success.
    public static let placementTolerance: CGFloat = 4

    /// Put one window in one rectangle, and **believe the frame, not the return code.**
    ///
    /// Both writes can answer `.success` while the app ignores the size it was handed — a fixed-size
    /// panel does exactly that — and a card that said "Moved Inbox to the left half" about a window that
    /// stayed put is the same lie the reveal made until tonight. So the answer is a re-read of the
    /// window's own rectangle, polled for a moment because a move animates.
    ///
    /// Size first, then position: an app that clamps a position against its current size would otherwise
    /// refuse the new position for a window it has not resized yet. Nothing here moves the cursor.
    ///
    /// `async`, and the wait is a `Task.sleep` rather than a `Thread.sleep`: this runs on the main
    /// actor, and blocking it for half a second to watch a window animate would freeze the notch during
    /// the act the user is watching for. The same reason the reveal polls without sleeping.
    public static func place(_ candidate: WindowAct.Candidate, to rect: CGRect) async -> Bool {
        guard let window = element(for: candidate) else { return false }
        var size = rect.size
        var origin = rect.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &origin) else { return false }
        let sized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString,
                                                 positionValue)
        guard sized == .success, moved == .success else { return false }
        return await settles(at: rect, window: window)
    }

    /// Poll the window's own frame until it matches, or the short ceiling runs out.
    static func settles(at rect: CGRect, window: AXUIElement) async -> Bool {
        let deadline = Date().addingTimeInterval(placementSettleSeconds)
        while true {
            let now = frame(of: window)
            if abs(now.width - rect.width) <= placementTolerance,
               abs(now.height - rect.height) <= placementTolerance,
               abs(now.minX - rect.minX) <= placementTolerance,
               abs(now.minY - rect.minY) <= placementTolerance { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    static let placementSettleSeconds = 0.6
}
