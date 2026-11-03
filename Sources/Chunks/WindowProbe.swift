import AppKit
import ChunksKit
import Foundation

/// `--probe-windows [App]` — every window Chunks can see, and what each verb would ask about it.
///
/// Read-only by construction: nothing is raised, minimised, closed or quit, and the verbs are printed
/// as the *questions* the card would ask. That is the point — "close that window" is the one sentence
/// where a wrong resolution loses work he cannot get back, so the resolution and the wording have to be
/// inspectable before anyone says it out loud.
///
/// It runs the same gate the live turn runs: `WindowAct.resolve` for the window, `ToolLayer.question`
/// for the sentence, and `ToolLayer.alwaysAsks` for whether the card appears at all. A probe that
/// re-implemented any of the three would be a second opinion about his windows.
@MainActor
enum WindowProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe-windows") }

    private static func out(_ line: String) {
        print(line)
        Log.write(line)
    }

    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)

        // A locked or asleep screen enumerates nothing, and "Chunks can see no windows" would then be
        // a report about the login window rather than about the driver.
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0
            || ["loginwindow", "WindowServer"].contains(
                NSWorkspace.shared.frontmostApplication?.localizedName ?? "") {
            out("windows: SKIP: the display is asleep or at the login window, so there is nothing to "
                + "enumerate — re-run with the screen awake")
            exit(3)
        }

        let named = argumentAfterFlag("--probe-windows")
        let candidates = WindowDriver.candidates(appNamed: named)
        out("windows: \(candidates.count) window(s) Chunks can see"
            + (named.map { " in \($0)" } ?? "") + " — read-only, nothing was moved or closed")
        guard !candidates.isEmpty else {
            out("windows: FAIL — an awake screen published no windows at all, which is either a "
                + "missing Accessibility grant or a driver that stopped reading")
            exit(1)
        }
        for candidate in candidates.prefix(24) {
            let flags = [candidate.isFocused ? "focused" : nil,
                         candidate.isMinimized ? "minimised" : nil,
                         candidate.isReachable ? nil : "out of reach"].compactMap { $0 }
            out("  \(pad(candidate.appName, 22)) \"\(candidate.title)\"  "
                + "(\(Int(candidate.frame.origin.x)), \(Int(candidate.frame.origin.y)), "
                + "\(Int(candidate.frame.width))x\(Int(candidate.frame.height)))  pid "
                + "\(candidate.pid)\(flags.isEmpty ? "" : "  " + flags.joined(separator: ", "))")
        }
        if candidates.count > 24 { out("  …and \(candidates.count - 24) more") }
        // The floor is asserted on the real machine because only the real machine publishes the things
        // it exists to keep out. Measured 2026-11-03: Chrome hands Accessibility three "windows", two
        // of them untitled strips at 1710x41 and 1710x81, and `close Chrome` refused with "3 windows
        // answer that name" about one document. A strip is not a window a person means.
        let strips = candidates.filter {
            $0.frame.width < WindowDriver.minListedWidth || $0.frame.height < WindowDriver.minListedHeight
        }
        if !strips.isEmpty {
            let sizes = strips.map { "\($0.appName) \(Int($0.frame.width))x\(Int($0.frame.height))" }
            out("windows: FAIL — \(strips.count) strip(s) of window chrome were counted as windows "
                + "(\(sizes.joined(separator: ", "))), which turns an honest refusal into a wrong one")
            exit(1)
        }
        out("windows: every listed window is at least "
            + "\(Int(WindowDriver.minListedWidth))x\(Int(WindowDriver.minListedHeight)) — "
            + "no toolbar strip counted as a window")

        // The app to ask about: the one he named, or the frontmost one — the same choice a spoken
        // sentence makes when it says "this window".
        let target = named ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        var failures: [String] = []

        for verb in WindowAct.Verb.allCases {
            let request = Self.request(verb: verb, app: target, title: nil)
            let resolution = WindowAct.resolve(verb: verb, app: target, title: nil, in: candidates)
            switch resolution {
            case .one(let candidate):
                let asked = ToolLayer.alwaysAsks(request)
                let card = WindowAct.question(verb: verb, candidate: candidate)
                out("  \(pad("[DO:\(Self.tagName(verb)):\(target)]", 34)) → \(asked ? "ASKS" : "runs")"
                    + "  card: \"\(card)\"")
                // The contract that must never regress: the two verbs that lose work are asked about
                // even on a machine where nothing else is, and the two that do not are not.
                if asked != verb.isPermanent {
                    failures.append("\(verb.rawValue) is \(asked ? "asked" : "not asked") but "
                        + "\(verb.isPermanent ? "loses work" : "does not")")
                }
                if !card.contains(candidate.appName) {
                    failures.append("the card for \(verb.rawValue) does not name the app it acts on: "
                        + card)
                }
                if verb.isPermanent, !card.lowercased().contains("unsaved") {
                    failures.append("a permanent verb must say what it costs: \(card)")
                }
            case .ambiguous(let many):
                let refusal = WindowAct.refusal(verb: verb, app: target, title: nil,
                                                resolution: .ambiguous(many))
                out("  \(pad("[DO:\(Self.tagName(verb)):\(target)]", 34)) → REFUSED  "
                    + "\(many.count) windows answer that name")
                if refusal.isEmpty || !refusal.contains("Say which one") {
                    failures.append("an ambiguous name must be refused *with the list*: \(refusal)")
                }
            case .none:
                out("  \(pad("[DO:\(Self.tagName(verb)):\(target)]", 34)) → REFUSED  no window answers")
            case .appNotRunning(let name):
                out("  \(pad("[DO:\(Self.tagName(verb)):\(target)]", 34)) → REFUSED  \(name) is not running")
            case .unreachable(let candidate):
                let refusal = WindowAct.refusal(verb: verb, app: target, title: nil,
                                                resolution: .unreachable(candidate))
                out("  \(pad("[DO:\(Self.tagName(verb)):\(target)]", 34)) → REFUSED  "
                    + "\"\(candidate.title)\" is out of reach")
                if verb != .quit, refusal.isEmpty || !refusal.contains("reach") {
                    failures.append("an unreachable window must be refused with why it cannot be "
                        + "acted on, not with \"no such window\": \(refusal)")
                }
            case .notAWindow(let candidate):
                let refusal = WindowAct.refusal(verb: verb, app: target, title: nil,
                                                resolution: .notAWindow(candidate))
                out("  \(pad("[DO:\(Self.tagName(verb)):\(target)]", 34)) → REFUSED  "
                    + "\"\(candidate.title)\" is the desktop, not a window")
                if !refusal.contains("desktop") {
                    failures.append("the desktop must be refused by naming it as the desktop, which is "
                        + "the only way he learns why nothing happened: \(refusal)")
                }
            }
        }

        // A named title, when he gave one, so the resolution path that matters most is visible: the
        // sentence names a window, not an app.
        if let named, let title = argumentAfterFlag("--title") {
            let resolution = WindowAct.resolve(verb: .close, app: named, title: title, in: candidates)
            switch resolution {
            case .one(let candidate):
                out("windows: \"\(title)\" in \(named) resolves to one window — card: "
                    + "\"\(WindowAct.question(verb: .close, candidate: candidate))\"")
            case .ambiguous(let many):
                out("windows: \"\(title)\" in \(named) answers \(many.count) windows — refused, "
                    + "and both are listed")
            case .none:
                out("windows: FAIL — \"\(title)\" in \(named) resolved to nothing, and it is on screen")
                failures.append("a visible window was not resolved by its own title")
            case .appNotRunning:
                out("windows: \(named) is not running")
            case .unreachable(let candidate):
                out("windows: \"\(title)\" in \(named) is open but out of reach — named, and "
                    + "refused rather than offered: "
                    + WindowAct.refusal(verb: .close, app: named, title: title,
                                         resolution: .unreachable(candidate)))
                if candidate.isReachable {
                    failures.append("an unreachable candidate claimed to be reachable")
                }
            case .notAWindow(let candidate):
                out("windows: \"\(title)\" in \(named) is the desktop — refused, not offered: "
                    + WindowAct.refusal(verb: .close, app: named, title: title,
                                         resolution: .notAWindow(candidate)))
                if !candidate.isDesktop {
                    failures.append("a candidate refused as the desktop was not marked as one")
                }
            }
        }

        // The read half (TASKS.md 3.12 level 1): what a `[DO:list_windows:…]` would stage into the
        // next turn. Asserted, not just printed — a listing that overflowed its budget or silently
        // dropped windows would be a partial read described as a complete one.
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName
        if let block = OpenWindows.block(app: named, frontmost: frontmost, in: candidates) {
            out("windows: a listing would carry \(block.listed) window(s), \(block.bytes) bytes, "
                + "\(block.leftOut) left out")
            for line in block.text.split(separator: "\n").prefix(8) { out("  │ \(line)") }
            if block.bytes > OpenWindows.maxBlockBytes {
                failures.append("the listing is \(block.bytes) bytes, past the "
                    + "\(OpenWindows.maxBlockBytes)-byte budget")
            }
            if block.leftOut > 0, !block.text.contains("not listed") {
                failures.append("\(block.leftOut) window(s) were left out and the listing does not "
                    + "say so — a partial list that reads as a complete one")
            }
            for promise in ["not the screenshot", "not instructions"] where
                !block.text.lowercased().contains(promise) {
                failures.append("the listing no longer says it is \(promise)")
            }
        } else {
            failures.append("\(candidates.count) window(s) were enumerated but a listing came back empty")
        }

        if failures.isEmpty {
            out("windows: PASS — enumeration, wording, the listing and the always-asked contract hold")
            exit(0)
        }
        for failure in failures { out("windows: FAIL — \(failure)") }
        exit(1)
    }

    /// `--probe-geometry 'Safari|Inbox|left'` — where a move *would* put a window, and nothing else.
    ///
    /// Geometry is the one act in this app that writes a rectangle, and every rectangle bug this repo has
    /// hit produced a plausible number rather than an error: a click at double the intended offset on
    /// Retina, an aim that clamped to the last row, a window list that reached above the top of the
    /// display. So the rectangle a move would write has to be readable at a terminal before anyone says
    /// the sentence out loud — and it has to come from the same `WindowPlacementPolicy.decide` the act
    /// runs, because a probe that did its own maths would be a second authority over his screen and the
    /// first place the two disagreed would be the bug.
    static var isGeometryRequested: Bool { CommandLine.arguments.contains("--probe-geometry") }

    static func requestedGeometry() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-geometry"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let body = CommandLine.arguments[index + 1].trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    static func runGeometry(_ body: String) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let surfaces = WindowDriver.surfaces()
        out("geometry: \(surfaces.count) display(s) — global top-left logical points")
        for surface in surfaces {
            out("  \(surface.index). \(pad(surface.name, 22)) whole "
                + "(\(Int(surface.globalFrame.minX)), \(Int(surface.globalFrame.minY)), "
                + "\(Int(surface.globalFrame.width))x\(Int(surface.globalFrame.height)))  usable "
                + "(\(Int(surface.usableFrame.minX)), \(Int(surface.usableFrame.minY)), "
                + "\(Int(surface.usableFrame.width))x\(Int(surface.usableFrame.height)))"
                + (surface.isMain ? "  main" : ""))
        }

        guard let parsed = DoRequest.parse("move_window:\(body)"),
              case .moveWindow(let app, let title, let target) = parsed else {
            out("geometry: refused at parse — \"\(body)\" is not a window and a place Chunks knows. "
                + "A coordinate is never accepted: \(WindowPlacementPolicy.vocabulary).")
            exit(1)
        }

        let resolution = WindowAct.resolvePlacement(app: app, title: title,
                                                   in: WindowDriver.candidates(appNamed: app))
        let decision = WindowPlacementPolicy.decide(target: target, app: app, title: title,
                                                    resolution: resolution, surfaces: surfaces)
        guard case .place(let candidate, let surface, let rect) = decision else {
            let reason: String
            if case .refused(let why) = decision { reason = why } else { reason = "no placement" }
            out("geometry: refused — \(reason)")
            out("geometry: no card would be built, so an Allow could never have led to a window moving")
            exit(0)
        }

        out("geometry: window — \"\(candidate.title)\" in \(candidate.appName) (pid \(candidate.pid)) "
            + "at (\(Int(candidate.frame.minX)), \(Int(candidate.frame.minY)), "
            + "\(Int(candidate.frame.width))x\(Int(candidate.frame.height)))")
        out("geometry: would write — display \(surface.index) (\(surface.name)) at "
            + "(\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.width))x\(Int(rect.height)))")
        let card = WindowPlacementPolicy.question(target: target, candidate: candidate)
        out("geometry: the card would ask \"\(card)\" and nothing was moved")

        var failures: [String] = []
        // The two properties that make this slice safe, asserted on the real display rather than only
        // in the unit fixtures: a placed window stays inside the area a window may occupy, and it stays
        // inside the display it was placed on. A rectangle outside either one is invariant 1's bug —
        // plausible, silent, and a window he has to drag back by hand.
        if !surface.usableFrame.contains(rect) {
            failures.append("the frame \(rect) escapes the usable area \(surface.usableFrame) — "
                + "it would land under the menu bar or the Dock")
        }
        if !surface.globalFrame.contains(rect) {
            failures.append("the frame \(rect) is not on display \(surface.index) at all")
        }
        if rect.width < WindowPlacementPolicy.minWindowSize.width
            || rect.height < WindowPlacementPolicy.minWindowSize.height {
            failures.append("the frame is smaller than anything a person can type into: "
                + "\(rect.width)x\(rect.height)")
        }
        if ToolLayer.alwaysAsks(parsed) {
            failures.append("a move is reversible and loses nothing, so it must not be always-asked")
        }
        if !parsed.invalidatesTheScreen {
            failures.append("a move changes the screen, so a plan with a pixel step after it must "
                + "wait for a fresh capture — and it only does that if this says true")
        }
        for failure in failures { out("geometry: FAIL — \(failure)") }
        if failures.isEmpty {
            out("geometry: PASS — the rectangle is inside the display, usable, and the contract holds")
            exit(0)
        }
        exit(1)
    }

    /// The request the shell would stage for this verb, so the probe asks the same question the card
    /// does rather than a paraphrase of it.
    private static func request(verb: WindowAct.Verb, app: String,
                                title: String?) -> DoRequest {        switch verb {
        case .focus: return .focusWindow(app: app, title: title)
        case .minimize: return .minimizeWindow(app: app, title: title)
        case .close: return .closeWindow(app: app, title: title)
        case .quit: return .quitApp(name: app)
        }
    }

    private static func tagName(_ verb: WindowAct.Verb) -> String {
        switch verb {
        case .focus: return "focus_window"
        case .minimize: return "minimize_window"
        case .close: return "close_window"
        case .quit: return "quit_app"
        }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func argumentAfterFlag(_ flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              index + 1 < CommandLine.arguments.count else { return nil }
        let next = CommandLine.arguments[index + 1]
        return next.hasPrefix("--") ? nil : next
    }
}
