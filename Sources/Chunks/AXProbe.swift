import AppKit
import ChunksKit
import Foundation

/// `Chunks --probe-ax 855,276` — a read-only look at what the Accessibility hit test finds at
/// a point in global **top-left** coordinates.
///
/// This exists because the whole act path is unverifiable in unit tests. The coordinate flip
/// (image pixels → AppKit bottom-left → AX top-left), the window-list filtering and the
/// pressable-ancestor walk each return a *plausible number* rather than an error when they are
/// wrong, which is the failure mode invariant 1 was written about. Printing what a real point
/// resolves to is the only way to see it.
///
/// It never presses. A command-line flag that could act on any point on screen would be the one
/// surface in Chunks that bypasses the confirm card, and the card is the feature.
enum AXProbe {

    /// `--probe-voice` — read-only: which voices *this signed bundle* is offered, best first.
    ///
    /// Worth a flag because the answer is not what `System Settings > Spoken Content` shows. The
    /// log names the voice Chunks chose; this names every voice it could have chosen, which is the
    /// difference between "pick a better one" and "there isn't one on this machine".
    static var isVoiceProbeRequested: Bool { CommandLine.arguments.contains("--probe-voice") }

    static func runVoiceProbe() -> Never {
        let voices = LocalTTSClient.allVoices()
        let ranked = SpeechVoices.ranked(voices)
        print("probe-voice: \(voices.count) voices on this machine, \(ranked.count) English")
        for voice in ranked.prefix(12) {
            print("  q\(voice.quality) \(voice.language) "
                + "\(SpeechVoices.displayName(for: voice)) [\(voice.identifier)]")
        }
        let chosen = SpeechVoices.pick(from: voices)
        print("probe-voice: Chunks would speak with "
            + "\(chosen.map { SpeechVoices.displayName(for: $0) } ?? "nothing")")
        exit(0)
    }

    /// `--probe-ax x,y`, or nil if the flag is absent or malformed.
    static func requestedPoint() -> CGPoint? {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-ax"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let parts = CommandLine.arguments[index + 1].split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// `--named "…"` alongside `--probe-ax`: the label the model would have used.
    ///
    /// The name fallback is a second, independent resolution of the same request, and until the
    /// 2026-10-04 "free claude code" turn it could only be exercised by talking to the app. A probe
    /// that prints it says whether an aim that missed the icon would still have pressed it — and
    /// still never presses.
    static func requestedLabel() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--named"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let label = CommandLine.arguments[index + 1].trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    /// `--probe-desktop`, with no argument to parse.
    static var isRequested: Bool {        CommandLine.arguments.contains("--probe-desktop")
    }

    /// Print the answer and exit. Never returns, so a probe can never fall through into
    /// launching the menu bar app — a probe that also opened panels would confuse the next
    /// person reading the output.
    static func run(at point: CGPoint) -> Never {
        let trusted = AXTDriver.isTrusted()
        print("probe-ax: point=\(point) accessibility=\(trusted)")
        Log.write("probe-ax: point=\(point) trusted=\(trusted)")
        guard trusted else {
            print(AXTDriver.PressResult.permissionMissing.userFacingReason)
            exit(2)
        }

        let candidates = AXTDriver.currentWindowCandidates()
        print("probe-ax: \(candidates.count) layer-0 windows owned by other apps")
        for window in candidates.prefix(5) {
            print("  pid=\(window.pid) bounds=\(window.bounds) owner=\(window.ownerName ?? "-")")
        }
        let covering = AXTDriver.topmostWindow(candidates, containing: point)
        print("probe-ax: window at point = \(covering.map { "\($0.ownerName ?? "?") pid \($0.pid)" } ?? "none")")

        // Both act resolutions come before the pixel's own answer, because "nothing pressable
        // here" is the ordinary case for a text field — exiting on it would hide the one line that
        // says whether typing is possible. Nothing here stops the probe.
        if let label = requestedLabel() {
            print("probe-ax: asked for \"\(label)\" at that point, the press path resolves to:")
            if let target = AXTDriver.target(label: label, at: point) {
                let info = target.info
                let center = info.frame.map { "(\($0.midX), \($0.midY))" } ?? "-"
                print("  \(info.role ?? "-")/\(info.elementLabel) in "
                      + "\(info.appName ?? "pid \(info.pid)") at \(center) "
                      + "verb=\(target.action) answeredByName=\(target.snapped)")
                let decision = PolicyGate.decide(target: info.policyTarget(bundleID: nil),
                                                 alwaysAllowedBundleIDs: [])
                print("  policy=\(decision) — the card would ask "
                      + "\"Press \(info.elementLabel)?\"")
            } else {
                print("  nothing — the aim missed and no name answered it, so the card refuses")
            }

            // The same point read as a *field*, which is a second, independent resolution: a text
            // input answers to no press action, so `target(label:at:)` will not return it, and the
            // only way to learn whether "type in the message box" can find the box is to ask the
            // typing resolver. It never focuses anything and never posts a keystroke; the one
            // attribute it can write is the switch that makes Chromium publish its tree, which the
            // act path writes on the same read anyway.
            print("probe-ax: the same ask read as a field:")
            if let field = AXTDriver.typeTarget(label: label, at: point) {
                let info = field.info
                let center = info.frame.map { "(\($0.midX), \($0.midY))" } ?? "-"
                let focused = AXTDriver.hasFocus(field.element)
                print("  \(info.role ?? "-")/\(info.elementLabel) in "
                      + "\(info.appName ?? "pid \(info.pid)") at \(center) "
                      + "answeredByName=\(field.snapped) focusedNow=\(focused)")
                let decision = PolicyGate.decide(target: info.policyTarget(bundleID: nil),
                                                 alwaysAllowedBundleIDs: [])
                print("  policy=\(decision) — the card would ask \"Type … into "
                      + "\(AXTDriver.fieldLabel(for: info))?\", and nothing is posted until "
                      + "focusedNow is true")
            } else {
                print("  nothing editable there, so a [TYPE:…] would be refused")
            }

            // And as a list that moves, because a scroll aims at a scroller that is usually two
            // ancestors above whatever the point hit — the one act whose target is not the thing
            // under the cursor.
            print("probe-ax: the same ask read as a scroller:")
            if let scroller = AXTDriver.scrollTarget(direction: .down, label: label, at: point) {
                let info = scroller.info
                let center = info.frame.map { "(\($0.midX), \($0.midY))" } ?? "-"
                print("  \(info.role ?? "-")/\(info.elementLabel) in "
                      + "\(info.appName ?? "pid \(info.pid)") at \(center) "
                      + "verb=\(scroller.action) answeredByName=\(scroller.snapped)")
                let question = ActionRequest.scrollQuestion(elementLabel: info.elementLabel,
                                                            direction: .down, pages: 1)
                print("  the card would ask \"\(question)\"")
            } else {
                print("  nothing there moves, so a [SCROLL:…] would be refused")
            }
        }

        guard let element = AXTDriver.elementAt(point) else {
            print("probe-ax: nothing found — no candidate window contains that point")
            exit(3)
        }

        print("probe-ax: role=\(element.role ?? "-") title=\(element.title ?? "-") "
              + "description=\(element.descriptionText ?? "-")")
        print("probe-ax: app=\(element.appName ?? "-") pid=\(element.pid) "
              + "frame=\(element.frame.map { String(describing: $0) } ?? "-") "
              + "pressable=\(element.isPressable)")

        let bundleID = NSRunningApplication(processIdentifier: pid_t(element.pid))?.bundleIdentifier
        let decision = PolicyGate.decide(target: element.policyTarget(bundleID: bundleID),
                                         alwaysAllowedBundleIDs: [])
        print("probe-ax: bundle=\(bundleID ?? "-") policy=\(decision) pressable=\(element.isPressable)")
        if element.isPressable {
            print("probe-ax: the card would ask \"Press \(element.elementLabel) in "
                  + "\(element.appName ?? "that app")?\"")
        } else {
            print("probe-ax: the card would refuse — "
                  + AXTDriver.PressResult.notPressable(element: element).userFacingReason)
        }
        print("probe-ax: stopped here — this mode never presses")
        exit(0)
    }

    /// `Chunks --probe-desktop` — read-only: what the desktop's own icons publish.
    ///
    /// `currentWindowCandidates()` asks for on-screen windows *excluding desktop elements*, so
    /// the Finder desktop is never in the list Chunks hit-tests against. That is the whole
    /// reason "click the file on my desktop" answered `nothing found`: the point was on the
    /// wallpaper layer, which the candidate filter had already thrown away. Before changing that
    /// filter, this prints what an icon actually is — role, title, frame, and decisively which
    /// actions it answers to, because a press needs `AXPress`/`AXPick` and an `AXImage` may have
    /// neither.
    static func runDesktop() -> Never {
        let trusted = AXTDriver.isTrusted()
        print("probe-desktop: accessibility=\(trusted)")
        guard trusted else {
            print(AXTDriver.PressResult.permissionMissing.userFacingReason)
            exit(2)
        }

        // Which windows does the *unfiltered* list put at a desktop point? The filtered list is
        // what the act path uses, so both are printed and the difference is visible.
        let filtered = AXTDriver.currentWindowCandidates()
        let raw = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                   as? [[String: Any]]) ?? []
        print("probe-desktop: \(filtered.count) candidate windows, \(raw.count) in the raw list")
        var offLayer = 0
        for entry in raw where entry[kCGWindowLayer as String] as? Int != 0 && offLayer < 12 {
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            offLayer += 1
            print("  layer=\(entry[kCGWindowLayer as String] as? Int ?? -999) "
                  + "owner=\(entry[kCGWindowOwnerName as String] as? String ?? "-") "
                  + "name=\"\(entry[kCGWindowName as String] as? String ?? "-")\" bounds=\(rect)")
        }

        guard let finder = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == "com.apple.finder" }) else {
            print("probe-desktop: Finder is not running, so there is no desktop to read")
            exit(3)
        }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(app, 1.0)

        print("probe-desktop: windows offered by Finder pid \(finder.processIdentifier)")
        guard let windows = copyElements(app, kAXWindowsAttribute as String), !windows.isEmpty else {
            print("probe-desktop: Finder published no windows")
            exit(4)
        }
        for window in windows {
            let title = copyString(window, kAXTitleAttribute as String) ?? "-"
            let subrole = copyString(window, kAXSubroleAttribute as String) ?? "-"
            let children = copyElements(window, kAXChildrenAttribute as String) ?? []
            print("  window title=\"\(title)\" subrole=\(subrole) children=\(children.count)")
            for child in children.prefix(40) {
                describeTree(child, depth: 0)
            }
        }
        print("probe-desktop: stopped here — this mode never presses")
        exit(0)
    }

    /// Print one element and its children to a bounded depth, with the actions a press could use.
    private static func describeTree(_ element: AXUIElement, depth: Int) {
        let role = copyString(element, kAXRoleAttribute as String) ?? "-"
        let title = copyString(element, kAXTitleAttribute as String) ?? ""
        let position = copyValue(element, kAXPositionAttribute as String)
        let size = copyValue(element, kAXSizeAttribute as String)
        var actions: CFArray?
        _ = AXUIElementCopyActionNames(element, &actions)
        let names = (actions as? [String]) ?? []

        let indent = String(repeating: "  ", count: depth + 1)
        print("\(indent)role=\(role) title=\"\(title.prefix(40))\" "
              + "at=\(frameDescription((position, size))) "
              + "actions=\(names.isEmpty ? "-" : names.joined(separator: ","))")

        guard depth < 2 else { return }
        for child in (copyElements(element, kAXChildrenAttribute as String) ?? []).prefix(20) {
            describeTree(child, depth: depth + 1)
        }
    }

    private static func frameDescription(_ value: (AnyObject?, AnyObject?)) -> String {
        guard let position = value.0, let sizeValue = value.1 else { return "-" }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &dimensions)
        return "(\(point.x), \(point.y) \(dimensions.width)x\(dimensions.height))"
    }

    private static func copyString(_ element: AXUIElement, _ name: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func copyValue(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func copyElements(_ element: AXUIElement, _ name: String) -> [AXUIElement]? {
        guard let raw = copyValue(element, name) as? [AnyObject] else { return nil }
        // An AX children array is an array of elements by contract, so this is a bridge rather
        // than a check: `raw.compactMap { $0 as? AXUIElement }` is a warning that never resolves.
        return raw.map { $0 as! AXUIElement }
    }
}
