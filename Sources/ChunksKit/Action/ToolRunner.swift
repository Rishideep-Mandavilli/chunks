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
    /// `@MainActor` because this launches GUI applications, and the shell that calls it already
    /// lives on the main actor.
    @MainActor
    public static func run(_ request: DoRequest) async -> Bool {
        switch request {
        case .addRoutine, .removeRoutine, .addReminder, .cancelReminder:
            // Not this type's work. The schedule is the file the panel shows and `CompanionManager`
            // owns it, so the routine tools are applied there and never reach this executor.
            // Returning false rather than trapping: if the routing ever changes, the user reads
            // "the routine was not added" instead of nothing at all.
            return false

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
            return revealInFinder(path: path)

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

    /// Show one thing in Finder: a folder is opened, anything else is selected inside its parent.    ///
    /// The two routes are deliberately different APIs. `open` on a directory gives the window he
    /// asked for — the folder *is* the place; `activateFileViewerSelecting` on a file opens its
    /// parent with the file highlighted, which is what "show me that PDF in Finder" means. Handing
    /// a file to `open` instead would launch whatever owns it, which is a different promise from the
    /// one the card made.
    static func revealInFinder(path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        let url = URL(fileURLWithPath: path)
        if isDirectory.boolValue {
            return NSWorkspace.shared.open(url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
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
