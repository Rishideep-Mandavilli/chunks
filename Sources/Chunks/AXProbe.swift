import AppKit
import AVFoundation
import ChunksKit
import IOKit.pwr_mgt
import QuartzCore
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

    /// Whether the read-only development tools may run in this build.
    ///
    /// Debug builds always have them — that is what they are for, and every one of them is how a
    /// claim in `AGENTS.md` gets checked. A release build needs `CHUNKS_DEV=1` in its environment,
    /// which a copied `.app` will not have, so the probes cannot be used by whoever the app is
    /// shared with.
    static var developmentToolsAllowed: Bool {
        #if DEBUG
        return true
        #else
        return ProcessInfo.processInfo.environment["CHUNKS_DEV"] == "1"
        #endif
    }

    /// Whether any development flag was actually asked for, so a release build can say so rather
    /// than launch as if the command had been accepted.
    static var developmentFlagRequested: Bool {
        CommandLine.arguments.contains { $0.hasPrefix("--probe-") || $0.hasPrefix("--render-") }
    }

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

    /// `--probe-semantic "app=WhatsApp name=Send"` — read-only: what a *named* control resolves to.
    ///
    /// The semantic path is the one place Chunks can act without ever having seen the screen, so it
    /// needs a check that contains no point. This asks the live accessibility tree and prints what
    /// the card would say, and it goes through `ActionRequest.parseAct` — the same door a spoken
    /// turn goes through — so a body this probe cannot read is a body the model must not be writing.
    /// Like every other probe it never presses and never types.
    static func requestedSemanticBody() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-semantic"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let body = CommandLine.arguments[index + 1].trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    static func runSemantic(_ body: String) -> Never {
        let trusted = AXTDriver.isTrusted()
        print("probe-semantic: \"\(body)\" accessibility=\(trusted)")
        guard trusted else {
            print(AXTDriver.PressResult.permissionMissing.userFacingReason)
            exit(2)
        }
        // The real parse door, so "the probe found it" and "the app would act on it" stay the same
        // claim. A body that reads as a point is not what this flag is for — but say which of the
        // two point forms it was, because `app=… x,y:label` parses now and a probe that called it
        // unreadable would be lying about the grammar.
        guard let request = ActionRequest.parseAct(body), let named = request.semanticTarget else {
            if let point = ActionRequest.parseAct(body)?.pointTarget, let app = point.appName {
                print("probe-semantic: a pixel aim qualified by \(app) — (\(Int(point.x)), "
                      + "\(Int(point.y))) \"\(point.label)\". It needs the screenshot to map, so "
                      + "check the aim itself with --probe-ax and --probe-crop; the app is a "
                      + "requirement the hit test has to answer.")
            } else {
                print("probe-semantic: not a named control — \(body) would resolve by coordinates "
                      + "(use --probe-ax x,y --named \"…\") or reach the user as text")
            }
            exit(2)
        }
        print("probe-semantic: read as \(named.questionPhrase)")
        // Which window the search is standing in, because "no such control" and "I did not look
        // where the control lives" print the same sentence to the user. On 2026-10-18 the desktop
        // icon ask answered a refusal while the pixel route found the same icon, and this line is
        // what separates a locked screen with no icons published from a search started at the
        // wrong root.
        let surface = AXTDriver.surface(ownedByNamed: named.app)
        let windowDescription = surface.map { "\($0.front.ownerName ?? "?") pid \($0.front.pid) "
            + "layer \($0.front.layer) bounds \($0.front.bounds) "
            + "veto union \($0.visibleBounds)" }
            ?? "no on-screen window for that app"
        print("probe-semantic: searching \(windowDescription)")

        print("probe-semantic: as a control to press:")
        switch AXTDriver.resolve(named) {
        case .failure(let miss):
            print("  refusal — \(miss.userFacingReason)")
        case .success(let target):
            let info = target.info
            let center = info.frame.map { "(\($0.midX), \($0.midY))" } ?? "-"
            print("  \(info.role ?? "-")/\(info.elementLabel) in "
                  + "\(info.appName ?? "pid \(info.pid)") at \(center) verb=\(target.action)")
            let decision = PolicyGate.decide(target: info.policyTarget(bundleID: nil),
                                             alwaysAllowedBundleIDs: [])
            print("  policy=\(decision) — the card would ask \"Press \(info.elementLabel)?\"")
        }

        // Both readings of the same name, because a plan's type step needs a *field* and a field
        // usually advertises no press verb at all. Printing only the first would tell the user a
        // working message box was not there.
        print("probe-semantic: the same name read as a field:")
        switch AXTDriver.typeResolve(named) {
        case .failure(let miss):
            print("  refusal — \(miss.userFacingReason)")
        case .success(let field):
            let info = field.info
            let center = info.frame.map { "(\($0.midX), \($0.midY))" } ?? "-"
            print("  \(info.role ?? "-")/\(info.elementLabel) in "
                  + "\(info.appName ?? "pid \(info.pid)") at \(center) "
                  + "focusedNow=\(AXTDriver.hasFocus(field.element))")
            print("  the card would ask \"Type … into \(AXTDriver.fieldLabel(for: info))?\"")
        }

        // And as a list that moves, because a scroll's target is the scroller the name climbs out
        // of, not the thing the name matched — the one act whose resolution changes what was asked
        // about, and therefore the one whose card wording has to be checked before it is trusted.
        print("probe-semantic: the same name read as a scroller:")
        switch AXTDriver.scrollResolve(named, direction: .down) {
        case .failure(let miss):
            print("  refusal — \(miss.userFacingReason)")
        case .success(let scroller):
            let info = scroller.info
            let center = info.frame.map { "(\($0.midX), \($0.midY))" } ?? "-"
            print("  \(info.role ?? "-")/\(info.elementLabel) in "
                  + "\(info.appName ?? "pid \(info.pid)") at \(center) verb=\(scroller.action)")
            print("  the card would ask \""
                  + "\(ActionRequest.scrollQuestion(elementLabel: named.name, direction: .down, pages: 1))\"")
        }
        print("probe-semantic: stopped here — this mode never presses or types")
        exit(0)
    }

    /// `--probe-fields WhatsApp` — read-only: every field that app publishes, named the way the app
    /// names it.
    ///
    /// This exists because the first live plan failed on a name the *prompt* invented: it told the
    /// model to write `name="Message box"`, WhatsApp publishes something else, and a name that is
    /// wrong is refused by design. Rather than guess again, this prints the exact strings to put in
    /// `name=`. It types nothing and presses nothing.
    static func requestedFieldApp() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-fields"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let name = CommandLine.arguments[index + 1].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    static func runFields(_ app: String) -> Never {
        guard AXTDriver.isTrusted() else {
            print(AXTDriver.PressResult.permissionMissing.userFacingReason)
            exit(2)
        }
        let sweep = AXTDriver.editableFields(ownedByNamed: app)
        print("probe-fields: \(app) — \(sweep.fields.count) field(s) Chunks could type into, "
            + "\(sweep.elementsRead) elements read"
            + (sweep.budgetSpent ? " — BUDGET SPENT, the walk stopped before the tree ended" : ""))
        for field in sweep.fields {
            let center = field.frame.map { "(\($0.midX), \($0.midY))" } ?? "-"
            print("  \(field.role ?? "-") title=\"\(field.title ?? "-")\" "
                  + "description=\"\(field.descriptionText ?? "-")\" at \(center)")
            // The words the app itself publishes, in the form the tag needs. A name the model cannot
            // read off the screen is a name it will not write, so this is the fix for a prompt that
            // teaches a plausible-sounding string.
            for candidate in [field.title, field.descriptionText] {
                if let words = candidate, !words.trimmingCharacters(in: .whitespaces).isEmpty {
                    print("    → [TYPE:app=\(app) name=\"\(words)\"|…]")
                    break
                }
            }
        }
        print("probe-fields: stopped here — this mode types nothing")
        exit(0)
    }

    /// `--probe-crop "x,y,w,h|aimX,aimY"` — read-only: where an aim inside a circled region lands.
    ///
    /// The draw-and-speak turn shows the model a crop, so its grid is stretched over that crop and
    /// the answer has to be mapped back into the region's real rectangle before it can be hit-tested.
    /// That composition — rect flip, aim, point flip — is what a unit test can only assert in the
    /// abstract, and each step returns a plausible number when wrong. This prints the same three
    /// calls the live turn makes, then runs the ordinary point resolution on the result.
    ///
    /// The picture's pixel size is taken as the region's point size, which changes nothing for a
    /// grid answer and is stated for a pixel answer; the region is what he drew, not a resized file.
    static func requestedCropAim() -> (crop: LogicalRect, aim: CGPoint)? {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-crop"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let halves = CommandLine.arguments[index + 1].split(separator: "|", maxSplits: 1)
        guard halves.count == 2 else { return nil }
        let numbers = halves[0].split(separator: ",")
        let coords = halves[1].split(separator: ",")
        let value: (Substring) -> Double? = { Double(String($0)) }
        guard numbers.count == 4, coords.count == 2,
              let x = value(numbers[0]), let y = value(numbers[1]),
              let w = value(numbers[2]), let h = value(numbers[3]),
              let aimX = value(coords[0]), let aimY = value(coords[1]) else { return nil }
        return (crop: LogicalRect(x: x, y: y, width: w, height: h),
                aim: CGPoint(x: aimX, y: aimY))
    }

    static func runCrop(crop: LogicalRect, aim: CGPoint) -> Never {
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 900)
        let imageFrame = ScreenshotGeometry.appKitRect(fromTopLeftGlobal: crop,
                                                      primaryScreenHeight: primaryHeight)
        print("probe-crop: region=\(Int(crop.minX)),\(Int(crop.minY)) "
            + "\(Int(crop.width))x\(Int(crop.height)) pt → "
            + "appKit frame=(\(imageFrame.minX), \(imageFrame.minY), "
            + "\(imageFrame.width), \(imageFrame.height)) "
            + "in a \(primaryHeight)pt-tall global space")
        guard let appKit = ScreenshotGeometry.appKitGlobalPoint(
            x: Double(aim.x), y: Double(aim.y),
            imageWidth: crop.width, imageHeight: crop.height,
            imageFrame: imageFrame) else {
            print("probe-crop: the region has no size, so nothing can be aimed in it")
            exit(2)
        }
        let point = ScreenshotGeometry.axGlobalPoint(appKitGlobalPoint: appKit,
                                                    primaryScreenHeight: primaryHeight)
        print("probe-crop: aim \(aim) in the region's grid → \(point) — resolving it:")
        run(at: point)
    }

    /// `--probe-mic` — read-only: what opening the microphone actually costs, reused engine against
    /// a fresh one, measured on this machine rather than argued about.
    ///
    /// The retry path replaces `AVAudioEngine` after a refusal, which is the only recovery that works
    /// when macOS has not finished releasing the device — but a new engine builds a new audio-unit
    /// graph, and if that were slow it would be the wrong second attempt. This prints each cycle's
    /// wall-clock so the cold start, the warm reuse and the fresh allocation are three separate
    /// numbers instead of an assumption. It never transcribes, never opens a stream to a model, and
    /// stops every engine it starts.
    static var isMicProbeRequested: Bool { CommandLine.arguments.contains("--probe-mic") }

    /// How many cycles to run. Five is enough to see the cold-start outlier and the warm median.
    static let micProbeCycles = 5

    /// One engine start, chased with **the app's own** retry schedule.
    ///
    /// The probe measures the recovery the user actually gets, not a simpler one invented for the
    /// check. Returns the milliseconds the successful `start()` took and how many attempts it needed.
    private static func startChasing(_ engine: AVAudioEngine,
                                    lastRefusal: inout String?) -> (ms: Int, attempts: Int)? {
        let schedule = [0.0] + BuddyDictationManager.microphoneRetryWaits
        for (index, wait) in schedule.enumerated() {
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            let clock = CACurrentMediaTime()
            do {
                engine.prepare()
                try engine.start()
                engine.stop()
                return (Int((CACurrentMediaTime() - clock) * 1000), index + 1)
            } catch {
                lastRefusal = "\(error)"
            }
        }
        return nil
    }

    static func runMicProbe() -> Never {
        var reused: [Int] = []
        var fresh: [Int] = []
        var allocated: [Int] = []
        var chased = 0
        var refused = 0
        var lastRefusal: String?

        func tap(on engine: AVAudioEngine) -> Double {
            let node = engine.inputNode
            let format = node.outputFormat(forBus: 0)
            node.removeTap(onBus: 0)
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
            return format.sampleRate
        }

        var standing = AVAudioEngine()
        var hertz = tap(on: standing)
        var started = false
        for cycle in 1...micProbeCycles {
            // The path a second press takes: the same engine, stopped and started again.
            if let open = startChasing(standing, lastRefusal: &lastRefusal) {
                reused.append(open.ms)
                if open.attempts > 1 { chased += 1 }
                started = true
            } else {
                reused.append(-1); refused += 1
            }

            // The path a retry takes now: release the old client, build a new engine, start it.
            let built = CACurrentMediaTime()
            let next = AVAudioEngine()
            allocated.append(Int((CACurrentMediaTime() - built) * 1000))
            hertz = tap(on: next)
            if let open = startChasing(next, lastRefusal: &lastRefusal) {
                fresh.append(open.ms)
                if open.attempts > 1 { chased += 1 }
                started = true
            } else {
                fresh.append(-1); refused += 1
            }
            standing = next
            _ = cycle
        }

        func summary(_ label: String, _ values: [Int]) -> String {
            let good = values.filter { $0 >= 0 }
            guard !good.isEmpty else { return "\(label): every attempt refused" }
            let sorted = good.sorted()
            return "\(label): median \(sorted[sorted.count / 2])ms · fastest \(sorted.first!)ms "
                + "· slowest \(sorted.last!)ms · \(good.count)/\(values.count) opened"
        }

        print("probe-mic: \(MicrophoneDevice.report.oneLine) · this probe opened it: \(started)")
        print("  " + summary("reuse the same engine ", reused))
        print("  " + summary("start a fresh engine ", fresh))
        print("  " + summary("allocate alone       ", allocated))
        print("probe-mic: cycle 1 is the cold start after launch; the rest are warm.")
        if chased > 0 {
            print("probe-mic: \(chased) opening(s) needed a wait first — that is the "
                + "device-release chase doing its job.")
        }

        // Three outcomes, and the difference is the whole point. A device that is *busy* is a fact
        // about the machine at this second — Chrome or another Chunks holding the input — and a red
        // line for it would teach everyone to ignore red lines. A 0 Hz format is a real fault: this
        // build cannot see an input at all.
        if refused == 0 { exit(0) }
        if hertz <= 0 {
            print("SKIP: no microphone exists on this machine (the input reports 0 Hz)")
            exit(1)
        }
        print("SKIP: the input was held by another process through "
            + "\(BuddyDictationManager.microphoneRetryWaits.reduce(0, +))s of chasing — "
            + "\(refused) of \(micProbeCycles * 2) openings refused")
        if let lastRefusal { print("  last refusal: \(lastRefusal)") }
        exit(3)
    }

    /// `--probe-controls Shortcuts` — read-only: every pressable control an app publishes, and the
    /// exact words it publishes it under.
    ///
    /// Added for the Shortcuts gallery refusal of 2026-10-27: a tile the user could see and name,
    /// which `app=Shortcuts name="stop sleep"` said did not exist. Every other probe answers one
    /// question about one point; this prints the vocabulary, which is the only way to tell a wrong
    /// name from a broken search.
    static func requestedControlApp() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-controls"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let app = CommandLine.arguments[index + 1].trimmingCharacters(in: .whitespaces)
        return app.isEmpty ? nil : app
    }

    static func runControls(_ app: String) -> Never {
        guard AXTDriver.isTrusted() else {
            print(AXTDriver.PressResult.permissionMissing.userFacingReason)
            exit(2)
        }
        let sweep = AXTDriver.pressableControls(ownedByNamed: app)
        print("probe-controls: \(app) — \(sweep.controls.count) pressable control(s), "
            + "\(sweep.elementsRead) elements read"
            + (sweep.budgetSpent ? " — BUDGET SPENT, the walk stopped early" : ""))
        // Menu rows first meant the 60 printed lines were 60 menu items on any browser, and the
        // candidates check in verify.sh filters `AXMenuBarItem|AXMenuItem` out of that output to find
        // its fixture — so it found nothing, skipped, and the web-content ranking went unverified on
        // every run. The page's own controls are what the check needs to see, so they come first.
        func isMenuRow(_ control: AXTDriver.ControlSweep.Control) -> Bool {
            let role = control.info.role ?? ""
            return role == "AXMenuItem" || role == "AXMenuBarItem" || role == "AXMenu"
        }
        let listed = sweep.controls.filter { !isMenuRow($0) } + sweep.controls.filter { isMenuRow($0) }
        for control in listed.prefix(60) {
            let info = control.info
            let center = info.frame.map { "(\($0.midX), \($0.midY))" } ?? "-"
            print("  \(info.role ?? "-")/\(control.subrole ?? "-") "
                + "title=\"\(info.title ?? "-")\" desc=\"\(info.descriptionText ?? "-")\" "
                + "at \(center) verbs=\(control.actions.joined(separator: ","))")
            if !control.childLabels.isEmpty {
                let quoted = control.childLabels.prefix(6).map { "\"\($0)\"" }.joined(separator: " ")
                print("    children: \(quoted)")
            }
        }
        print("probe-controls: stopped here — nothing is pressed")
        exit(0)
    }

    /// `--probe-candidates 'app=Chrome name=Run' [820,240]` — read-only: what the *ranking* resolves,
    /// next to what the named search says about the same words.
    ///
    /// `--probe-semantic` answers a refusal for controls a user can plainly see in a browser, because
    /// Chromium puts the words in a child `AXStaticText` and the name search reads only the element
    /// itself. This runs the same body through both routes and prints the exact sentence the confirm
    /// card would ask, so "the ranker found it" stays a claim about the card rather than about a
    /// number. The optional second argument is an aim in global top-left logical points — the same
    /// space `--probe-ax` wants — and it only ever separates candidates the words left level.
    ///
    /// Nothing is pressed. A door that could press would be the one surface that skips the card.
    static func requestedCandidates() -> (target: SemanticTarget, aim: CGPoint?)? {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-candidates"),
              index + 1 < CommandLine.arguments.count,
              let target = SemanticTarget.parse(CommandLine.arguments[index + 1]) else { return nil }
        var aim: CGPoint?
        if index + 2 < CommandLine.arguments.count {
            let parts = CommandLine.arguments[index + 2].split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
            aim = CGPoint(x: x, y: y)
        }
        return (target, aim)
    }

    static func runCandidates(_ target: SemanticTarget, aim: CGPoint?) -> Never {
        guard AXTDriver.isTrusted() else {
            print(AXTDriver.PressResult.permissionMissing.userFacingReason)
            exit(2)
        }
        print("probe-candidates: \(target.questionPhrase) aim=\(aim.map { "(\($0.x), \($0.y))" } ?? "none")")
        print("probe-candidates: the route that runs today —")
        switch AXTDriver.resolve(target) {
        case .success(let found):
            print("  named search resolves \(found.info.role ?? "-")/"
                + "\(found.info.elementLabel) — the ranking is not needed here")
        case .failure(let miss):
            print("  refusal — \(miss.userFacingReason)")
        }

        guard let sweep = AXTDriver.candidateControls(ownedByNamed: target.app) else {
            print("probe-candidates: \(target.app) has no on-screen window to read")
            exit(1)
        }
        print("probe-candidates: \(sweep.candidates.count) pressable control(s) in veto bounds "
            + "\(sweep.windowBounds), window the user is looking at \(sweep.contentBounds), "
            + "displays \(AXTDriver.visibleDisplayBounds()), "
            + "\(sweep.elementsRead) elements read"
            + (sweep.budgetSpent ? " — BUDGET SPENT, the walk stopped early" : ""))
        // The unnamed ones, which is what this route exists for: a control with an empty title is
        // invisible to a name search, so the list is the proof of the hole and, once the ranking works,
        // the proof of what filled it.
        let unnamed = sweep.candidates.filter { $0.ownNames.isEmpty }
        print("probe-candidates: \(unnamed.count) of them publish no name of their own —")
        for candidate in unnamed.prefix(20) {
            let center = candidate.frame.map { "(\($0.midX), \($0.midY))" } ?? "no frame"
            let inside = candidate.childrenText.prefix(4).map { "\"\($0)\"" }.joined(separator: " ")
            print("  \(candidate.role) at \(center)"
                + (inside.isEmpty ? " children: -" : " children: \(inside)"))
        }

        // The candidates the words reach, best first, so a refusal can be told apart from "the words
        // were never in the tree". `aim` only annotates this list: the live named route has no point
        // to measure against, which is why it is named, so the verdict below comes from the same
        // door a press goes through rather than from a second implementation of it.
        let ranked = CandidateRanker.rank(label: target.name, aim: aim,
                                          windowBounds: sweep.windowBounds,
                                          candidates: sweep.candidates)
        for (index, candidate) in ranked.prefix(5).enumerated() {
            let frame = candidate.element.frame
            let size = frame.map { "\(Int($0.width))×\(Int($0.height))" } ?? "no frame"
            let center = frame.map { "(\($0.midX), \($0.midY))" } ?? "-"
            print("  \(index + 1). \(candidate.element.role) \(candidate.evidence.phrase) "
                + "\"\(candidate.matchedText)\" score=\(candidate.textScore) at \(center) \(size)"
                + (aim != nil ? " \(Int(candidate.distanceToAim ?? -1))pt from the aim" : ""))
        }
        switch AXTDriver.candidateResolve(target) {
        case .failure(let miss):
            print("probe-candidates: refused — \(miss.userFacingReason)")
            print("probe-candidates: stopped here — nothing is pressed")
            exit(1)
        case .success(let found):
            let info = found.target.info
            let center = info.frame.map { "(\($0.midX), \($0.midY))" } ?? "no frame"
            let question = CandidateRanker.question(for: found.ranked, app: target.app,
                                                    windowBounds: found.contentBounds)
            let decision = PolicyGate.decide(target: info.policyTarget(bundleID: nil),
                                             alwaysAllowedBundleIDs: [],
                                             askBeforePressing: false,
                                             inferredAim: found.ranked.evidence == .childText)
            print("probe-candidates: resolved \(info.role ?? "-") verb=\(found.target.action) "
                + "at \(center) in \(info.appName ?? "pid \(info.pid)")")
            print("probe-candidates: the card would ask \"\(question)\"")
            print("probe-candidates: policy with asking off — \(decision) — "
                + (found.ranked.evidence == .childText
                   ? "the words came from inside the control, so the card asks even on a machine "
                   + "that is not asked about anything"
                   : "the app published these words itself, which is the evidence the named route "
                   + "has always acted on without a question"))
        }
        print("probe-candidates: stopped here — nothing is pressed")
        exit(0)
    }

    /// `--probe-remind "stretch|40 min"` — read-only: what a reminder tag would ask, and when it
    /// would really say itself.
    ///
    /// The half of the tool a unit case cannot check is the clock: `at 21:00` is today or tomorrow
    /// depending on the hour this runs at, and the card has to say the one that is true. Nothing is
    /// armed — a flag that could write the schedule would be the one surface that skips the confirm
    /// card, and the file this probe touches is the one he reads in the panel.
    static func requestedReminderBody() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-remind"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let body = CommandLine.arguments[index + 1].trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    static func runReminder(_ body: String) -> Never {
        print("probe-remind: the tag would be [DO:\(body)]")
        guard let request = DoRequest.parse(body) else {
            print("probe-remind: refused at parse — the whole tag is shown to him as text and "
                + "nothing is armed. The when must be one of: 40 min, 2 hours, 3 days, at 21:00, "
                + "9 pm, tomorrow at 07:30.")
            exit(1)
        }
        // The same two steps the card takes: resolve against this clock, then ask in those words.
        let resolved: DoRequest
        if case .addReminder(let text, let timing) = request {
            resolved = .addReminder(text: text, timing: ReminderStore.resolve(timing))
        } else {
            resolved = request
        }
        let question = ToolLayer.question(for: resolved)
        print("probe-remind: the card would ask \"\(question)\" — \(question.count) of "
            + "\(DoRequest.maxQuestionCharacters) characters")
        if case .addReminder(_, let timing) = resolved {
            let fireAt = timing.date(from: Date())
            print("probe-remind: it would say itself at "
                + Self.reminderStamp.string(from: fireAt) + " · "
                + ReminderStore.spoken(fireAt: fireAt))
        }
        print("probe-remind: nothing was armed, and \(ReminderStore.defaultURL.path) was not written")
        exit(0)
    }

    private static let reminderStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm:ss"
        return formatter
    }()

    /// `--probe-awake` — read-only in effect: what the sleep policy would decide, and whether this
    /// machine takes the assertion at all.
    ///
    /// The decision is a unit case; the *refusal* is not. macOS can say no to a power assertion, and
    /// the panel row has to be able to tell "on" from "holding", so the probe asks for one, reads the
    /// status, and releases it in the same breath. Nothing is left held: a flag that kept his laptop
    /// awake would be the exact thing the switch exists to make his choice.
    static var isAwakeProbeRequested: Bool { CommandLine.arguments.contains("--probe-awake") }

    @MainActor static func runAwakeProbe() -> Never {
        let routines = RoutinesStore.load()
        let reminders = ReminderStore.load()
        let armed = routines.routines.filter(\.isEnabled).count + reminders.reminders.count
        let enabled = UserDefaults.standard.bool(forKey: SleepPolicy.settingKey)
        print("probe-awake: switch \(enabled ? "on" : "off") · \(armed) thing(s) armed · "
            + "policy says " + (SleepPolicy.shouldHold(enabled: enabled,
                                                       anythingArmed: armed > 0)
                                ? "hold" : "let the Mac sleep"))
        // Built before the print: a string interpolation cannot be split across two concatenated
        // literals, and a probe that will not compile is a probe nobody runs.
        let row = SleepPolicy.describe(holding: false, enabled: enabled, armedCount: armed)
        print("probe-awake: the row would read \"\(row)\"")

        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Chunks probe — released immediately" as CFString, &id)
        if status == kIOReturnSuccess {
            IOPMAssertionRelease(id)
            print("probe-awake: the machine took the request and it has been released — the app's "
                + "own hold would work")
        } else {
            print("probe-awake: the machine refused (status \(status)) — the row must say so rather "
                + "than showing the switch as a hold")
        }
        exit(0)
    }

    /// `--probe-command` — read-only in effect: run **one fixed, harmless program** through the
    /// command tool and print what came back.
    ///
    /// Deliberately takes no argument. A flag that ran whatever it was handed would be the exact
    /// door the parser exists to close, and the thing worth checking is not "can it run `curl`" but
    /// "does `Process` start, does the output come back, does the timeout path exist". `date` prints
    /// a line; `true` prints nothing, which is the other half of the report card has to distinguish.
    static var isCommandProbeRequested: Bool {
        CommandLine.arguments.contains("--probe-command")
    }

    static func runCommandProbe() -> Never {
        // Awaited on the main actor over a run loop, not bridged with a semaphore. `ToolRunner.run`
        // is `@MainActor` because it launches GUI applications, and the old shape of this probe
        // blocked the main thread waiting for a `Task` that needed that thread — which hung the run
        // the moment a main-actor call was added to it. Measured 2026-10-31: the probe printed three
        // lines and sat there until it was killed.
        Task { @MainActor in
            // `caffeinate -u -t 5` outlives the 3-second watching window and then ends on its own, so
            // this is the third outcome the card has to report honestly: a command that is still
            // running is not a command that failed, and it is not one Chunks killed.
            for argv in [["date"], ["true"], ["caffeinate", "-u", "-t", "5"]] {
                let outcome = await ToolRunner.runCommand(argv: argv)
                let first = outcome.output.split(separator: "\n").first
                    .map(String.init) ?? "(no output)"
                // Three verdicts, not two. `caffeinate -u -t 5` outlives the watching window by
                // design, and until 2026-10-31 the probe called that "finished" — the same word it
                // uses for `date`, on a card that would then tell the user his six-hour hold had
                // already ended.
                let verdict = outcome.stillRunning ? "still running"
                    : outcome.succeeded ? "finished" : "did not succeed"
                print("probe-command: \(argv.joined(separator: " ")) — \(verdict) "
                    + "· \(outcome.output.count) chars · first line: \(first)")
            }
            // The floor under a caller that cannot carry output. `ToolRunner.run` answered `false`
            // for a command without starting it — and because `run_command` is the one tool always
            // asked about, the card-answer path went through exactly that function, so no approved
            // command ever ran. This proves the same program runs through *that* door too.
            let bypassed = await ToolRunner.run(.runCommand(argv: ["true"]))
            print("probe-command: ToolRunner.run(.runCommand) — "
                + (bypassed ? "executed" : "did not execute"))
            exit(0)
        }
        RunLoop.main.run()
        // Only reached if the run loop stops, which it does not. A probe that fell through here would
        // exit 0 and read as a pass on a run that printed nothing, so the code says otherwise.
        exit(1)
    }

    /// `--probe-reveal "Memora"` — read-only: which thing on this disk a reveal would open.
    ///
    /// The name search is the half that cannot be tested in a unit case, because it depends on what
    /// is actually in his folders. This prints the verdict and never opens a window: a command-line
    /// flag that could act is the one surface that skips the confirm card.
    static func requestedReveal() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-reveal"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let target = CommandLine.arguments[index + 1].trimmingCharacters(in: .whitespaces)
        return target.isEmpty ? nil : target
    }

    static func runReveal(_ target: String) -> Never {
        let home = NSHomeDirectory()
        print("probe-reveal: \"\(target)\" · roots: "
            + FinderReveal.searchRoots(home: home).joined(separator: ", "))
        switch FinderReveal.resolve(target, home: home) {
        case .found(let path):
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            print("probe-reveal: one match — \(isDir.boolValue ? "folder" : "file") at \(path)")
            print("probe-reveal: the card would ask \"Show "
                + RevealPolicy.label(for: path) + " in Finder?\" and nothing was opened")
        case .ambiguous(let paths):
            print("probe-reveal: \(paths.count) things share that name, so Chunks asks instead of choosing:")
            for path in paths { print("  \(path)") }
        case .nothing:
            print("probe-reveal: nothing on this disk answers to it, so the tool is refused "
                + "before a card is built")
        case .refused(let why):
            print("probe-reveal: refused — \(why)")
        }
        exit(0)
    }

    /// `--probe-open 'TextEdit|notes.md'` — read-only: what `[DO:open_file_with:…]` would decide.
    ///
    /// This verb puts a file's contents on screen inside an application the model named, so its two
    /// sharpest answers — "that file holds credentials" and "that is outside the folders I may open" —
    /// are security rules. They used to be written inside `CompanionManager`, where a unit test cannot
    /// reach them and a probe could not quote them without performing the act, so the decision moved to
    /// `OpenFilePolicy` and this function only supplies the two facts the shell owns: what the disk
    /// says, and which apps are installed. It opens nothing.
    static func requestedOpen() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-open"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let body = CommandLine.arguments[index + 1].trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    static func runOpen(_ body: String) -> Never {
        let home = NSHomeDirectory()
        print("probe-open: \"\(body)\" · roots: "
            + FinderReveal.searchRoots(home: home).joined(separator: ", "))
        let parsed = DoRequest.parse("open_file_with:\(body)")
        guard case .openFileWith(let app, let written)? = parsed else {
            print("probe-open: refused at parse — the tag is not an app and a file Chunks can name, "
                + "so it never reaches the disk and no card is built")
            exit(1)
        }
        let installed = ToolRunner.isInstalled(app)
        let resolved = OpenFilePolicy.Resolved(written: written)
        let outcome = OpenFilePolicy.decide(app: app, written: written,
                                            resolved: resolved, appExists: installed)
        print("probe-open: app \"\(app)\" installed=\(installed) · disk: \(resolved)")
        if case .opens(let namedApp, let path) = outcome {
            let request = DoRequest.openFileWith(app: namedApp, path: path)
            print("probe-open: one match — \(path)")
            print("probe-open: the card would ask \"\(ToolLayer.question(for: request))\" "
                + "and nothing was opened")
            print("probe-open: asks even with the switch off? "
                + (ToolLayer.alwaysAsks(request) ? "yes" : "no"))
            exit(0)
        }
        let refusal = OpenFilePolicy.refusal(for: outcome)
        print("probe-open: refused — \(refusal)")
        print("probe-open: no card is built, so an Allow could never have led to a file opening")
        guard !refusal.isEmpty else {
            print("probe-open: BUG — an outcome that cannot proceed produced no sentence, "
                + "so he would have been shown an empty card")
            exit(1)
        }
        exit(0)
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

// MARK: - The memory trust rule, against his real file

extension AXProbe {

    /// `--probe-memory` — read-only: run the real `memory.md` through the replacement rules and
    /// print what the app would do, without touching the file.
    ///
    /// The rule this checks is not arithmetic: an inference must never retire something he said, and
    /// his own correction must be able to. A unit case proves the function; this proves the wiring,
    /// because it loads *his* file into a temporary copy and drives the same `MemoryStore.propose`
    /// the live turn calls. Nothing is written to his path — the copy is deleted before this returns.
    static var isMemoryProbeRequested: Bool { CommandLine.arguments.contains("--probe-memory") }

    static func runMemoryProbe() -> Never {
        let real = MemoryStore.defaultURL()
        guard let text = try? String(contentsOf: real, encoding: .utf8) else {
            print("probe-memory: SKIP — no memory.md at \(real.path) yet")
            exit(3)
        }
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chunks-probe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let copy = scratch.appendingPathComponent("memory.md")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try? text.write(to: copy, atomically: true, encoding: .utf8)

        let store = MemoryStore(fileURL: copy, today: "2026-10-28")
        print("probe-memory: \(store.facts.count) fact(s) in his file · "
            + "\(store.byteCount)/\(MemoryStore.byteCap) bytes · "
            + "\(store.facts.filter { $0.origin == .said }.count) marked as his own")
        for fact in store.facts.prefix(6) {
            print("  \(fact.origin == .said ? "he said " : "inferred ") · \(fact.text)")
        }

        // Seed one line of each kind so the two rules are actually exercised on a real store,
        // whatever his file happens to hold today.
        _ = store.propose(section: .notes, text: "keeps his notes in bear",
                          claim: .said, hisWords: "I keep my notes in bear")
        guard let spoken = store.facts.first(where: { $0.text.contains("bear") }),
              spoken.origin == .said else {
            print("probe-memory: FAIL — the store would not mark a fact he said")
            exit(1)
        }

        // 1. An inference must not overwrite it.
        let overwrite = store.propose(section: .notes, text: "keeps his notes in obsidian",
                                      supersedes: "bear")
        let refused = { if case .refusedSupersede = overwrite { return true }; return false }()
        print("probe-memory: an inferred replacement of his own line → "
            + (refused ? "refused, as it must be" : "ALLOWED, WHICH IS THE BUG"))
        guard refused else { exit(1) }

        // 2. His own correction must land, or the cap would make the file permanently wrong.
        let correction = store.propose(section: .notes, text: "keeps his notes in obsidian",
                                       claim: .said, hisWords: "I keep my notes in obsidian now",
                                       supersedes: "bear")
        let replaced = { if case .replaced = correction { return true }; return false }()
        print("probe-memory: the same correction, said by him → "
            + (replaced ? "replaced" : "REFUSED, WHICH IS ALSO A BUG"))
        print("probe-memory: his file at \(real.path) was not written")
        exit(replaced ? 0 : 1)
    }
}
