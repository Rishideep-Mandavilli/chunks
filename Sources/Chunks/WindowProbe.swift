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
                         candidate.isMinimized ? "minimised" : nil].compactMap { $0 }
            out("  \(pad(candidate.appName, 22)) \"\(candidate.title)\"  "
                + "(\(Int(candidate.frame.origin.x)), \(Int(candidate.frame.origin.y)), "
                + "\(Int(candidate.frame.width))x\(Int(candidate.frame.height)))  pid "
                + "\(candidate.pid)\(flags.isEmpty ? "" : "  " + flags.joined(separator: ", "))")
        }
        if candidates.count > 24 { out("  …and \(candidates.count - 24) more") }

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

    /// The request the shell would stage for this verb, so the probe asks the same question the card
    /// does rather than a paraphrase of it.
    private static func request(verb: WindowAct.Verb, app: String,
                                title: String?) -> DoRequest {
        switch verb {
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
