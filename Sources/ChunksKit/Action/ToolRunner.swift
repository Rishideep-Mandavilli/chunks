import AppKit
import CoreAudio
import Foundation

/// Runs the tools a `[DO:…]` can name, on the real machine.
///
/// This is the **last** step of the act chain: the request has already been described in one
/// honest sentence by `ToolLayer`, and the user has already answered the card with Allow.
/// Nothing here decides whether to act — it performs what was approved and reports truthfully
/// whether it took effect, because the card's one-line result is the user's only evidence that
/// Chunks did what they agreed to.
public enum ToolRunner {

    /// The folders a user-installed app can legitimately live in.
    ///
    /// A fixed list rather than a search of the filesystem: `[DO:open_app:X]` names an
    /// *installed app*, and keeping the lookup inside these four directories is what makes it
    /// impossible for a prompt injection to aim the tag at an arbitrary path.
    public static let applicationDirectories: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "\(NSHomeDirectory())/Applications",
    ]

    /// Run an approved request. Returns whether it actually took effect.
    ///
    /// Find the window again, then perform the verb.
    ///
    /// Resolved a second time on purpose: the card can outlive the window, and acting on whatever now
    /// carries that title is not what he approved — the same re-read a press does before it lands. A
    /// window that is gone answers `false`, which reaches him as "it did not close" rather than as a
    /// claim about something else.
    @MainActor
    static func performWindowVerb(_ verb: WindowAct.Verb, app: String, title: String?) -> Bool {
        guard case .one(let candidate) = WindowAct.resolve(
            verb: verb, app: app, title: title, in: WindowDriver.candidates(appNamed: app))
        else { return false }
        switch verb {
        case .focus: return WindowDriver.focus(candidate)
        case .minimize: return WindowDriver.minimize(candidate)
        case .close: return WindowDriver.close(candidate)
        case .quit: return WindowDriver.quit(appNamed: app)
        }
    }

    /// Move one window to a named place. Returns whether the window **ended up there**.
    static func performMove(app: String, title: String?,
                            target: WindowPlacementPolicy.Target) async -> Bool {
        let resolution = WindowAct.resolvePlacement(app: app, title: title,
                                                   in: WindowDriver.candidates(appNamed: app))
        guard case .place(let candidate, _, let rect) = WindowPlacementPolicy.decide(
            target: target, app: app, title: title, resolution: resolution,
            surfaces: WindowDriver.surfaces())
        else { return false }
        return await WindowDriver.place(candidate, to: rect)
    }

    /// Run an approved effect and report what the screen did, not what the call answered.
    ///
    /// `run` answers "did LaunchServices take the request", which is not the question the card
    /// promised: measured 2026-11-05, `[DO:open_url:youtube]` opened the search, reported
    /// `Opened www.youtube.com/results?…`, and left his screen exactly where it was — the browser
    /// came up behind the window he was in. The reveal learned this lesson already: an effect is
    /// believed from the window on screen. This is that rule applied to the verbs that bring
    /// something forward.
    ///
    /// `@MainActor` for the same reason `run` is: this launches GUI applications and asks AppKit who
    /// is frontmost.
    @MainActor
    public static func runForOutcome(_ request: DoRequest) async -> OpenOutcome {
        // Who had the screen before the effect. This is what makes the second attempt safe: if the
        // front app at the decision point is neither the handler nor this one, he switched of his own
        // accord, and raising the browser over what he deliberately moved to is a worse bug than the
        // one being fixed.
        let baseline = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let opened = await run(request)
        guard opened else { return OpenOutcome(opened: false, cameForward: nil) }
        guard let handler = await handlerBundleID(for: request) else {
            // No handler to ask. An unknown bundle id is not a refusal, and saying so is the
            // difference between this check informing him and lying to him.
            return OpenOutcome(opened: true, cameForward: nil)
        }
        let forward = await ensureFrontmost(handler, unlessHeSwitchedTo: baseline)
        return OpenOutcome(opened: true, cameForward: forward)
    }

    /// Whether the app that owns what was just opened is frontmost, asking it once directly if not.
    ///
    /// `activates = true` is a request, not a result. This polls briefly, and on the first miss makes
    /// the one move that is unambiguously within what he approved — raising the app he named — before
    /// reporting. Nothing here moves the pointer, which is the invariant the press path is built on.
    ///
    /// The polls are short on purpose: this sits on the path that produces the card's outcome line,
    /// and a launch-led plan step waits on it before it resumes.
    @MainActor
    private static func ensureFrontmost(_ bundleID: String,
                                        unlessHeSwitchedTo baseline: String?) async -> Bool {
        if await isFrontmost(bundleID, within: 0.8) { return true }
        let now = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard now == nil || now == baseline else {
            // Something else holds the screen that did not hold it before the open. That is his doing,
            // and it wins: the effect he asked for is running, just not raised.
            return false
        }
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) else { return false }
        app.activate(options: [.activateAllWindows])
        return await isFrontmost(bundleID, within: 1.5)
    }

    @MainActor
    private static func isFrontmost(_ bundleID: String, within seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /// Which application owns the effect this request asked for, when that is knowable.
    @MainActor
    private static func handlerBundleID(for request: DoRequest) async -> String? {
        switch request {
        case .openApp(let name):
            guard let path = resolveApplicationPath(name: name,
                                                    candidates: installedApplications()) else { return nil }
            return Bundle(path: path)?.bundleIdentifier
        case .openURL(let url, let browser):
            if let browser,
               let path = resolveApplicationPath(name: browser, candidates: installedApplications()) {
                return Bundle(path: path)?.bundleIdentifier
            }
            guard let target = URL(string: url) else { return nil }
            return await defaultHandlerBundleID(for: target)
        case .openFileWith(let app, _):
            guard let path = resolveApplicationPath(name: app,
                                                    candidates: installedApplications()) else { return nil }
            return Bundle(path: path)?.bundleIdentifier
        case .runShortcut(let name):
            guard let url = DoRequest.shortcutURL(name: name) else { return nil }
            return await defaultHandlerBundleID(for: url)
        case .email(let address):
            guard let url = DoRequest.mailtoURL(address: address) else { return nil }
            return await defaultHandlerBundleID(for: url)
        default:
            return nil
        }
    }

    @MainActor
    private static func defaultHandlerBundleID(for url: URL) async -> String? {
        guard let appURL = try? await NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return Bundle(path: appURL.path)?.bundleIdentifier
    }

    /// The keyboard verb, run end to end: find the app, make sure it is the one holding the
    /// screen, then post the key.
    ///
    /// The front-of-queue check is not ceremony. A keystroke goes to the focused element of the
    /// focused application, so "press ⌘S in the editor" while his terminal is front would save the
    /// terminal's file — an act on the wrong machine-state, approved for the right one. The rule is
    /// the one the open verbs now use: raise it, then believe the screen rather than the request; and
    /// if the screen went somewhere he moved it himself, stop rather than fight him for it.
    @MainActor
    public static func runKey(app: String, body: String) async -> KeyEffect {
        guard let combo = KeyAction.parse(body) else { return .unreadableKey }
        guard let running = runningApplication(named: app) else { return .appNotFound(app) }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier
            != running.processIdentifier {
            running.activate(options: [.activateAllWindows])
            var waited = 0.0
            while NSWorkspace.shared.frontmostApplication?.processIdentifier
                != running.processIdentifier, waited < 2.0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 0.1
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == running.processIdentifier else {
                return .notFrontmost(app)
            }
        }

        // What the card was worded from. The driver re-reads the live focus and refuses if the act
        // means something else there — a Return that turns out to submit, not break a line.
        let expected = KeyAction.classify(combo, focusedRole: nil)
        let outcome = AXTDriver.keys(combo, pid: Int(running.processIdentifier),
                                     expected: expected)
        switch outcome {
        case .pressed(_, let focus): return .pressed(focus: focus)
        case .focusChanged(let reason, let focus): return .focusChanged(reason: reason, focus: focus)
        case .permissionMissing: return .permissionMissing
        }
    }

    /// The running application a person named, or nil when nothing running answers to it. A key
    /// cannot be sent to an app that is not up, and launching it is a different act with its own
    /// card — `[DO:open_app:]` — so this refuses rather than quietly doing two things.
    @MainActor
    public static func runningApplication(named name: String) -> NSRunningApplication? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.localizedName != nil
        }
        let exact = running.filter { $0.localizedName?.lowercased() == wanted }
        if let one = exact.first, exact.count == 1 { return one }
        if !exact.isEmpty { return exact.first }
        // The same half-name rule the rest of the app uses — "chrome" for "Google Chrome" — and the
        // same discipline: two that answer is a question, not a pick.
        let partial = running.filter { AXTDriver.matchesAppName(label: wanted,
                                                                owner: $0.localizedName ?? "") }
        return partial.count == 1 ? partial.first : nil
    }

    /// What a keyboard act did, in the four ways it can end.
    public enum KeyEffect: Sendable {
        case pressed(focus: AXTDriver.KeyFocus)
        case appNotFound(String)
        case notFrontmost(String)
        /// The live focus makes this a different act from the one approved. Refused, and the reason
        /// is the sentence he gets.
        case focusChanged(reason: String, focus: AXTDriver.KeyFocus)
        case unreadableKey
        case permissionMissing

        public var succeeded: Bool {
            if case .pressed = self { return true }
            return false
        }
    }

    /// The effect of an open, as the screen reports it.
    public struct OpenOutcome: Sendable {
        public let opened: Bool
        /// `nil` when there was no handler to ask — unknown, which is not the same claim as false.
        public let cameForward: Bool?

        public init(opened: Bool, cameForward: Bool?) {
            self.opened = opened
            self.cameForward = cameForward
        }
    }

    /// `@MainActor` because this launches GUI applications, and the shell that calls it already
    /// lives on the main actor.
    @MainActor
    public static func run(_ request: DoRequest) async -> Bool {
        switch request {
        case .key(let app, let body):
            return (await runKey(app: app, body: body)).succeeded
        case .addRoutine, .removeRoutine, .addReminder, .cancelReminder:
            // Not this type's work. The schedule is the file the panel shows and `CompanionManager`
            // owns it, so the routine tools are applied there and never reach this executor.
            // Returning false rather than trapping: if the routing ever changes, the user reads
            // "the routine was not added" instead of nothing at all.
            return false

        case .listWindows:
            // A read, not an act: the shell intercepts it before any card or executor, stages the
            // listing for the next turn, and nothing here runs. False rather than a trap, so a routing
            // mistake reads as "Chunks could see no windows" instead of crashing mid-turn.
            return false

        case .webOpen, .webClick, .webType:
            // The web bridge is shell work (a live socket to the Chrome extension), so these are
            // performed in `CompanionManager.runTool` and never reach this stateless executor. False
            // rather than a trap, so a routing mistake reads as a refusal instead of crashing.
            return false

        // The window verbs. Resolution already happened in the shell — a window is found against the
        // live tree *before* the card asks, the same order a press uses — so what arrives here names
        // the window that will really be acted on, and this only performs the verb.
        case .focusWindow(let app, let title):
            return performWindowVerb(.focus, app: app, title: title)
        case .minimizeWindow(let app, let title):
            return performWindowVerb(.minimize, app: app, title: title)
        case .closeWindow(let app, let title):
            return performWindowVerb(.close, app: app, title: title)
        case .quitApp(let name):
            return WindowDriver.quit(appNamed: name)

        case .moveWindow(let app, let title, let target):
            // Re-decided here, not remembered from the card: the window may have moved, another one may
            // have opened, and the display he meant may have been unplugged in the seconds since he
            // answered. `WindowPlacementPolicy.decide` is the same function `--probe-geometry` prints, so the
            // probe's rectangle and the act's rectangle cannot diverge.
            return await performMove(app: app, title: title, target: target)

        case .openFileWith(let app, let path):
            // The policy already ran: the shell resolved the path against `RevealPolicy`'s roots and
            // credential list before the card, exactly as a reveal does, because this puts the file's
            // contents on his screen in an app of his choosing.
            return await openFile(path, with: app)

        case .openApp(let name):
            guard let path = resolveApplicationPath(name: name, candidates: installedApplications())
            else {
                return false
            }
            let configuration = NSWorkspace.OpenConfiguration()
            // Bringing the app forward *is* what "Open Notes?" agreed to, and the rest of the
            // turn depends on it: an `[ACT]` in the same reply hit-tests by screen position, so a
            // window that opened behind another one would resolve to the wrong control. What
            // Chunks must not do is move the pointer or raise one of its own panels uninvited.
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: path), configuration: configuration
                )
                return true
            } catch {
                return false
            }

        case .setVolume(let percent):
            return setSystemVolume(percent: percent)

        case .reveal(let path):
            return await revealInFinder(path: path)

        case .runCommand(let argv):
            // **This used to `return false` without running anything**, with a comment saying the
            // caller has somewhere to put the output. That was true of one caller and invisible to
            // the others, and a tool the user had just approved on a card is not a tool that gets to
            // be quietly refused: `answerAct` reached for this function, and every `[DO:run_command:]`
            // since the tool shipped came back `caffeinate -u -t 7200 did not run.` — measured
            // 2026-10-31, twice, on two evenings, with no reason anywhere on the card.
            //
            // So the command runs here too. The shell's `runTool` is still the path that reports the
            // *output*, which is the only reason it exists; this is the floor under a caller that
            // cannot carry it, and it is deliberately able to fail in only one direction now.
            return await runCommand(argv: argv).succeeded

        case .openURL(let url, let browser):
            guard let target = URL(string: url) else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            // Same reasoning as `open_app`: the browser coming forward is the effect the user
            // agreed to, and a tab that opened behind another window is a result they cannot see.
            configuration.activates = true

            // A named browser means *that* browser. The card said Chrome, so defaulting to
            // whatever the machine prefers would be a different answer from the one asked.
            //
            // Success is the absence of an error, not the application handle: the handler hands
            // back an `NSRunningApplication?` and a browser already running can answer with nil
            // for a URL that opened in it perfectly well.
            if let browser,
               let path = resolveApplicationPath(name: browser, candidates: installedApplications()) {
                return await withCheckedContinuation { done in
                    NSWorkspace.shared.open([target],
                                            withApplicationAt: URL(fileURLWithPath: path),
                                            configuration: configuration) { _, error in
                        done.resume(returning: error == nil)
                    }
                }
            }
            if let browser {
                // A named browser means *that* browser. Falling through to the default opened the
                // URL in Safari while the outcome line said Chrome (AUDIT.md A-04).
                NSLog("[Chunks] tool: %@ is not installed — refusing rather than using the default",
                      browser)
                return false
            }
            return await withCheckedContinuation { done in
                NSWorkspace.shared.open(target, configuration: configuration) { _, error in
                    done.resume(returning: error == nil)
                }
            }

        case .runShortcut(let name):
            return await openScheme(DoRequest.shortcutURL(name: name))

        case .email(let address):
            return await openScheme(DoRequest.mailtoURL(address: address))
        }
    }

    /// Hand a built scheme URL to whatever owns it, and answer with whether the handover took.
    ///
    /// The same rule `openURL` documents: success is the absence of an error, not an application
    /// handle, because an app that is already running answers nil for a URL it opened perfectly
    /// well. `activates` is true because the app coming forward *is* the effect the card described —
    /// "Run the shortcut …?" that happens in a background Shortcuts is a result the user cannot see.
    @MainActor
    static func openScheme(_ url: URL?) async -> Bool {
        guard let url else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { done in
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                done.resume(returning: error == nil)
            }
        }
    }

    // MARK: - Opening an app

    /// Paths of the `.app` bundles in `applicationDirectories`, one level deep.
    /// Open one file in one named application, through `NSWorkspace` — the file route, not the
    /// explorer panel.
    ///
    /// Chosen over driving an editor's UI because a click on a file row is a guess about a picture, and
    /// this is a fact about the file system: the same app opens the same document whether its window is
    /// on this Space, another one, or closed. It also never moves his cursor.
    ///
    /// A missing file or an unknown app answers `false`, which reaches him as "`Code` did not open
    /// `notes.md`" — the two causes are different and he can see which one it was from the path on the
    /// card, so folding them into one line loses nothing he can act on.
    @MainActor
    static func openFile(_ path: String, with app: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: path),
              let appPath = resolveApplicationPath(name: app, candidates: installedApplications())
        else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            try await NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                              withApplicationAt: URL(fileURLWithPath: appPath),
                                              configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    /// Whether an application by that name is installed.
    ///
    /// Public because a refusal has to say *which half* failed: "Code did not open notes.md" about an
    /// app that is not on the machine sends him looking for a broken file. The shell asks before it
    /// builds a card, and so does `--probe-open`.
    public static func isInstalled(_ name: String) -> Bool {
        resolveApplicationPath(name: name, candidates: installedApplications()) != nil
    }

    static func installedApplications() -> [String] {
        let finder = FileManager.default
        var paths: [String] = []
        for directory in applicationDirectories {
            guard let entries = try? finder.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                paths.append(directory + "/" + entry)
            }
        }
        return paths
    }

    /// The pure half of the lookup: pick the candidate that *is* the named app, or `nil`.
    ///
    /// Matching is case-insensitive and tolerates the `.app` suffix being typed or omitted,
    /// because that is how people name apps. Beyond that it is deliberately strict: a name that
    /// is contained in exactly one candidate matches, but a name contained in several is
    /// ambiguous and returns `nil`. Launching a guess is worse than failing — the card would
    /// have said "Open Notes?" and something else would have appeared.
    static func resolveApplicationPath(name: String, candidates: [String]) -> String? {
        let needle = normalizedAppName(name)
        guard !needle.isEmpty else { return nil }

        if let exact = candidates.first(where: { normalizedAppName($0) == needle }) {
            return exact
        }
        let containing = candidates.filter { normalizedAppName($0).contains(needle) }
        return containing.count == 1 ? containing[0] : nil
    }

    /// Lower-cased, with the enclosing directory and the `.app` suffix removed.
    private static func normalizedAppName(_ path: String) -> String {
        let lastSegment = path.split(separator: "/").last.map(String.init) ?? path
        return lastSegment.replacingOccurrences(of: ".app", with: "").lowercased()
    }

    // MARK: - Volume

    /// CoreAudio's scalar volume for a percentage.
    ///
    /// The API takes 0.0...1.0; the user, the card and `DoRequest` all speak percent. Doing the
    /// division in one place is what keeps "40%" from becoming 40.0 — which is not a number
    /// CoreAudio accepts, and would fail rather than blast the speakers.
    static func scalar(for percent: Int) -> Float32 {
        Float32(min(max(percent, 0), 100)) / 100.0
    }

    /// Run one program with fixed arguments and no shell, and give back what it printed.
    ///
    /// Bounded on three axes the card cannot show. A **watching window**, because a command that
    /// waits for input would otherwise hang the notch forever — and the answer when the window runs
    /// out is "it is still running, here is its pid", never a silent kill. An **output cap**, because `log show` is megabytes and the
    /// turn is one line. And a **working directory of home**, so a relative path in an argument cannot
    /// reach a folder he did not name.
    ///
    /// The program is resolved against `DoRequest.commandSearchPaths` only, which is what makes the
    /// name on the card the whole decision: there is no `$PATH` inherited from a shell, and no way to
    /// name a binary by a path the user did not read.
    public static func runCommand(argv: [String]) async -> CommandOutcome {
        guard let program = argv.first else {
            return CommandOutcome(succeeded: false, stillRunning: false,
                                  output: "Chunks was asked to run an empty command")
        }
        let executable = DoRequest.commandSearchPaths
            .map { "\($0)/\(program)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else {
            return CommandOutcome(succeeded: false, stillRunning: false,
                                  output: "no \(program) in the folders Chunks looks in")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        // Output goes to a file, not a pipe. A pipe has to be drained concurrently or a chatty
        // command blocks writing to it and the timeout fires on a process that was never going to
        // finish — a deadlock that looks like a slow command.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-command-\(UUID().uuidString.prefix(8)).txt")
        FileManager.default.createFile(atPath: scratch.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: scratch) else {
            return CommandOutcome(succeeded: false, stillRunning: false,
                                  output: "Chunks could not collect the command's output")
        }
        process.standardOutput = handle
        process.standardError = handle

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            return CommandOutcome(succeeded: false, stillRunning: false,
                                  output: "\(program) refused to start")
        }

        let deadline = Date().addingTimeInterval(commandWatchSeconds)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            // **Left running on purpose.** He approved the whole command line on the card, and
            // `caffeinate -di -t 3600` — the ordinary "stop sleep for an hour" — does not return for
            // an hour. Killing it at a timeout would silently undo the thing he said yes to, which is
            // worse than a long-running process he can see in Activity Monitor. So Chunks stops
            // *watching*, says so, and names the pid, because "it ran" over a command that is
            // halfway through its life is the same lie this project keeps having to unlearn.
            let pid = process.processIdentifier
            try? handle.close()
            try? FileManager.default.removeItem(at: scratch)
            return CommandOutcome(
                succeeded: true, stillRunning: true,
                output: "still running as pid \(pid) — Chunks stopped watching it. "
                    + "It ends on its own, or you stop it in Activity Monitor.")
        }
        process.waitUntilExit()
        let status = process.terminationStatus
        try? handle.close()
        let text = (try? Data(contentsOf: scratch)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        try? FileManager.default.removeItem(at: scratch)
        let printed = tail(text, limit: commandOutputLimit)
        // A command that fails and prints nothing used to come back as an empty string, which the
        // card rendered as "caffeinate -u -t 21600 did not run." and nothing else — photographed
        // 2026-10-31 with no cause anywhere on the card or in the log. The exit code is the whole
        // diagnosis available, so it goes in the output rather than being dropped.
        if status != 0 && printed.isEmpty {
            return CommandOutcome(succeeded: false, stillRunning: false,
                                  output: "\(program) exited with status \(status) and printed nothing")
        }
        return CommandOutcome(succeeded: status == 0, stillRunning: false, output: printed)
    }

    /// What a command did, in the three states the card has to tell apart.
    ///
    /// `stillRunning` is not a synonym for `succeeded`. `caffeinate -di -t 21600` — the ordinary
    /// "keep this Mac awake for six hours" — is *supposed* to be running when Chunks stops watching,
    /// and reporting that as "finished" on the card is the lie this type exists to prevent: he would
    /// wait for a completion that only arrives in six hours, or believe a hold that already ended.
    public struct CommandOutcome: Sendable {
        public var succeeded: Bool
        public var stillRunning: Bool
        public var output: String

        public init(succeeded: Bool, stillRunning: Bool, output: String) {
            self.succeeded = succeeded
            self.stillRunning = stillRunning
            self.output = output
        }
    }

    /// How long Chunks watches a command for before it reports the result.
    ///
    /// A *watching* window, not a kill switch: a command that outlives it keeps running, because the
    /// user approved that exact line and `caffeinate -t 3600` is meant to last an hour. Long enough to
    /// see a real failure (`pmset -g` answers in well under a second), short enough that the card
    /// never sits on a command that is waiting for input.
    public static let commandWatchSeconds: TimeInterval = 3

    /// Characters of output the card can carry. The *tail*, because that is where a failure prints.
    public static let commandOutputLimit = 400

    private static func tail(_ text: String, limit: Int) -> String {
        let flattened = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard flattened.count > limit else { return flattened }
        return "…" + String(flattened.suffix(limit))
    }

    /// Show one thing in Finder: a folder is opened, anything else is selected inside its parent.
    ///
    /// The two routes are deliberately different APIs. `open` on a directory gives the window he
    /// asked for — the folder *is* the place; `activateFileViewerSelecting` on a file opens its
    /// parent with the file highlighted, which is what "show me that PDF in Finder" means. Handing
    /// a file to `open` instead would launch whatever owns it, which is a different promise from the
    /// one the card made.
    ///
    /// **And the answer is whether a window is on screen, not whether the request was made.** Measured
    /// 2026-11-03 on his Mac: he said "locate Ritesh.docx and show it to me", the log wrote
    /// `tool: Showed Ritesh.docx (in Downloads) in Finder.` — spoken, on the card, with a green tick —
    /// and no Finder window came up until he asked again. The reason is that
    /// `activateFileViewerSelecting` returns `Void`, and the line below it said `return true`. So this
    /// now asks the screen the same question `pressLanded` asks after a press whose return code lied:
    /// is there a Finder window on the folder this reveal was about?
    static func revealInFinder(path: String) async -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        let url = URL(fileURLWithPath: path)
        if isDirectory.boolValue {
            guard NSWorkspace.shared.open(url) else { return false }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        return await Self.revealLanded(path: path, isDirectory: isDirectory.boolValue)
    }

    /// Finder's window titles, right now — the desktop included, because a reveal of a folder on the
    /// desktop is a reveal that lands on it.
    static func finderWindowTitles() -> [String] {
        WindowDriver.candidates(appNamed: "Finder").map(\.title)
    }

    /// How long a reveal is given to put up a window, and how often to look.
    ///
    /// Finder opens a window asynchronously and normally answers in well under half a second, so the
    /// poll is short and the wait is a ceiling rather than a cost. The ceiling is the same one the
    /// press path uses for a launch, because the failure being caught is the same shape: the request
    /// was accepted and the screen never changed.
    static let revealWaitSeconds = 2.5
    static let revealPollSeconds = 0.15

    /// Whether the reveal actually showed him something.
    ///
    /// The rule is a name match, not a count. An earlier version also passed when Finder's window count
    /// grew, and that is wrong in the direction that matters: told to show a file in Downloads, Finder
    /// putting up a *Documents* window is a reveal that went somewhere else, and a card that said
    /// "Showed" over it would be the same lie as the one this function was written to end. So the only
    /// evidence accepted is a window titled with the folder the reveal is about — which also covers the
    /// idempotent case, where Finder raises the window it already had and nothing new appears.
    ///
    /// Two names are tried because Finder titles a window with the *display* name, which is localised
    /// while the path is not: `/Users/him/Documents` is "Documents" on an English account and something
    /// else on a Hindi one, and a rule that only knew the path component would report a working reveal
    /// as a failure.
    static func revealLanded(path: String, isDirectory: Bool, now: [String]) -> Bool {
        let folder = (path as NSString).deletingLastPathComponent
        // A directory reveal opens that directory; a file reveal opens its parent with the file
        // selected. Either way the window's title is a folder name, so that is the name to look for.
        let directory = isDirectory ? path : folder
        let names = Self.revealWindowNames(directory)
        guard !names.isEmpty else { return false }
        return now.contains { title in
            names.contains { $0.caseInsensitiveCompare(title) == .orderedSame }
        }
    }

    /// The names a Finder window may carry for one folder: the path component, and whatever the file
    /// system says the folder is called on this machine.
    static func revealWindowNames(_ directory: String) -> [String] {
        guard !directory.isEmpty else { return [] }
        let component = (directory as NSString).lastPathComponent
        let display = FileManager.default.displayName(atPath: directory)
        return Set([component, display]).filter { !$0.isEmpty }.sorted()
    }

    /// The polling half: ask the pure rule until it passes or the ceiling runs out.
    static func revealLanded(path: String, isDirectory: Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(revealWaitSeconds)
        while Date() < deadline {
            if revealLanded(path: path, isDirectory: isDirectory,
                            now: finderWindowTitles()) { return true }
            try? await Task.sleep(nanoseconds: UInt64(revealPollSeconds * 1_000_000_000))
        }
        return false
    }

    static func setSystemVolume(percent: Int) -> Bool {
        guard let deviceID = defaultOutputDevice() else { return false }
        let value = scalar(for: percent)

        // The master element is the clean answer when a device publishes one.
        if setVolume(value, on: deviceID, element: kAudioObjectPropertyElementMain) { return true }

        // Some devices expose no master element at all — plenty of Bluetooth headphones and
        // aggregate devices only have per-channel ones. A device that accepted one channel but
        // refused the other has not had *the* volume set, so that reports failure rather than
        // letting the card claim "Volume set to 40%" over a device still at 90.
        var attempted = 0
        var succeeded = 0
        for channel in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            var address = volumeAddress(element: channel)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            attempted += 1
            if setVolume(value, on: deviceID, element: channel) { succeeded += 1 }
        }
        return attempted > 0 && attempted == succeeded
    }

    /// The output device's current volume as a percent, or `nil` when it publishes no readable
    /// scalar.
    ///
    /// This exists so the write path can be verified on real hardware by writing back the value
    /// the device already has — a no-op that proves `AudioObjectSetPropertyData` is reachable
    /// without changing anything the user can hear.
    static func currentSystemVolumePercent() -> Int? {
        guard let deviceID = defaultOutputDevice() else { return nil }
        if let master = readVolume(on: deviceID, element: kAudioObjectPropertyElementMain) {
            return Int((master * 100).rounded())
        }
        // Per-channel devices publish stereo as two scalars; the average is what the user
        // hears as "the volume".
        let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
            .compactMap { readVolume(on: deviceID, element: $0) }
        guard !channels.isEmpty else { return nil }
        let average = channels.reduce(Float32(0), +) / Float32(channels.count)
        return Int((average * 100).rounded())
    }

    private static func readVolume(on deviceID: AudioDeviceID,
                                   element: AudioObjectPropertyElement) -> Float32? {
        var address = volumeAddress(element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: element)
    }

    private static func setVolume(_ value: Float32,
                                  on deviceID: AudioDeviceID,
                                  element: AudioObjectPropertyElement) -> Bool {
        var address = volumeAddress(element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var mutableValue = value
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                         UInt32(MemoryLayout<Float32>.size), &mutableValue) == noErr
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                               &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }
}
