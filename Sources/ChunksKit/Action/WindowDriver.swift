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
    public static func candidates(appNamed name: String? = nil) -> [WindowAct.Candidate] {
        var out: [WindowAct.Candidate] = []
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for app in apps {
            if let name, !AXTDriver.matchesAppName(label: name, owner: app.localizedName ?? "") {
                continue
            }
            guard out.count < maxWindowsTotal else { break }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            let focused = AXTDriver.copyAttribute(element, kAXFocusedWindowAttribute as String)
            var seen = 0
            for window in windows(of: element) {
                guard seen < maxWindowsPerApp, out.count < maxWindowsTotal else { break }
                seen += 1
                out.append(WindowAct.Candidate(
                    pid: Int(app.processIdentifier),
                    appName: app.localizedName ?? "",
                    title: AXTDriver.stringAttribute(window, kAXTitleAttribute as String)
                        ?? AXTDriver.stringAttribute(window, kAXDescriptionAttribute as String) ?? "",
                    frame: frame(of: window),
                    isMinimized: boolAttribute(window, kAXMinimizedAttribute as String),
                    isFocused: focused != nil && CFEqual(focused as CFTypeRef, window as CFTypeRef)))
            }
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
}
