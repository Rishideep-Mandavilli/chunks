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
