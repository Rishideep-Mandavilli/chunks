import AppKit
import AVFoundation
import ChunksKit
import Combine
import Security
import SwiftUI

/// Process entry point.
///
/// `@main` (rather than a top-level `main.swift`) so the launch path is properly
/// MainActor-isolated — AppKit requires it and Swift 6 will hard-error on it.
@main
struct ChunksMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            SelfTest.run()
            return
        }
        AppShell.shared.start()
    }
}

/// Runs one real turn end to end and prints what happened, then exits.
///
/// Exists because the interesting failures in this app are all invisible from the outside:
/// a card that never appears, a reply that parses to nothing, a model that is silently
/// unusable. "Press the hotkey and tell me what you see" is a fine manual check, but it
/// needs a human, it cannot run in CI, and it does not show the raw reply or the token
/// counts. This does all three.
///
///     swift run chunks --self-test
///     swift run chunks --self-test --question "what am I looking at?"
@MainActor
enum SelfTest {

    static func run() {
        func say(_ message: String) { print(message) }
        func flag(_ name: String) -> String? {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: name),
                  index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        say("Chunks self-test")
        say("  screen recording: \(CaptureEngine.hasScreenRecordingPermission() ? "granted" : "NOT granted")")
        say("  api key: \(KeychainStore.hasKey ? "present" : "MISSING")")
        for display in CaptureEngine.displays() {
            say("  display \(display.displayID) \(Int(display.frame.width))x\(Int(display.frame.height))pt "
                + "@\(display.backingScale)x\(display.isMain ? " main" : "")")
        }

        guard let display = CaptureEngine.mainDisplay() else {
            say("FAIL: no display")
            exit(1)
        }

        Task { @MainActor in
            do {
                let started = Date()
                let captured = try await CaptureEngine().capture(display: display, shapes: [])
                let image = captured.composited(with: [], display: display)
                say("  captured \(image.width)x\(image.height)px in "
                    + String(format: "%.0fms", Date().timeIntervalSince(started) * 1000))

                guard let png = ScreenCapture(image: image, globalRect: captured.globalRect).png() else {
                    say("FAIL: could not encode PNG")
                    exit(1)
                }
                say("  png: \(png.count / 1024) KB")

                let request = TurnRequest(
                    question: flag("--question") ?? "What am I looking at? Answer in one sentence.",
                    scope: .wholeScreen,
                    imageData: png,
                    imagePixelSize: captured.pixelSize,
                    memoryBlock: "")

                let replied = Date()
                var raw = ""
                let answer = try await BrainGateway.shared.ask(request) { raw += $0 }
                let elapsed = Date().timeIntervalSince(replied)

                say("  --- raw reply (\(raw.count) chars, \(String(format: "%.1f", elapsed))s) ---")
                for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
                    say("  | \(line)")
                }
                say("  --- parsed ---")
                say("  speech: \(answer.spokenText.isEmpty ? "(none)" : answer.spokenText)")
                let detail = answer.detailText.isEmpty ? "(none)"
                    : answer.detailText.replacingOccurrences(of: "\n", with: " / ")
                say("  detail: \(detail)")
                for target in answer.points {
                    let resolved = captured.globalPoint(forImagePixelX: target.x, target.y)
                    say("  point: image (\(Int(target.x)), \(Int(target.y))) -> screen "
                        + "(\(Int(resolved.x)), \(Int(resolved.y)))  [\(target.label)]")
                }
                if let proposal = answer.proposal, !proposal.isEmpty {
                    for addition in proposal.add {
                        say("  memory proposal: [\(addition.section.rawValue)] \(addition.fact)")
                    }
                }

                if answer.spokenText.isEmpty && answer.detailText.isEmpty {
                    say("FAIL: the reply parsed to nothing")
                    exit(1)
                }
                say("OK")
                exit(0)
            } catch {
                say("FAIL: \(error)")
                if let chunksError = error as? ChunksError {
                    say("  detail: \(chunksError.description)")
                }
                exit(1)
            }
        }

        // The turn's completion handlers — screen capture, the SSE stream — are delivered on
        // the main run loop. `app.run()` normally supplies it; in self-test there is no
        // app, so without this the task is scheduled and then nothing ever services it. The
        // loop never returns: the task above always calls `exit`.
        RunLoop.main.run()
    }
}

// MARK: - State

/// What the user is doing right now. Drives the pill's appearance and the hotkey's meaning.
enum ChunksPhase: Equatable {
    case idle
    case listening
    case capturing
    case thinking
    case speaking

    var label: String {
        switch self {
        case .idle: return "Hold ⌃⌥ to ask"
        case .listening: return "Listening…"
        case .capturing: return "Reading your screen…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "waveform"
        case .listening: return "mic.fill"
        case .capturing: return "camera.viewfinder"
        case .thinking: return "ellipsis.bubble"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    /// Whether a turn may begin from this phase.
    ///
    /// `.listening` is included deliberately. The hotkey sets the phase to `.listening` on
    /// the way *in* and calls `runTurn` on the way *out*, so a guard of `phase == .idle`
    /// rejected every turn: the app sat on the microphone icon forever and never showed a
    /// card. Spelled out here, and tested, rather than left as an inline comparison that
    /// looks fine until the hotkey is wired to it.
    var canStartTurn: Bool {
        switch self {
        case .idle, .listening: return true
        case .capturing, .thinking, .speaking: return false
        }
    }
}

@MainActor
final class AppShell: NSObject, ObservableObject {
    static let shared = AppShell()

    @Published private(set) var phase: ChunksPhase = .idle
    @Published private(set) var transcript: String = ""
    @Published private(set) var statusNote: String = ""
    @Published private(set) var hasPermission: Bool = false
    /// Where the model pointed, already resolved to global logical screen points.
    @Published private(set) var points: [ResolvedPoint] = []

    /// Marks the user drew, waiting to be sent with the next turn.
    private var pendingAnnotations: [AnnotationShape] = []
    private var lastCapture: ScreenCapture?

    private var app: NSApplication!
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private let capture = CaptureEngine()
    private let memory: MemoryStore
    private let panel = AnswerPanel()

    private override init() {
        memory = MemoryStore(fileURL: MemoryStore.defaultURL())
        super.init()
    }

    func start() {
        app = NSApplication.shared
        // Accessory, not regular: no Dock tile, no app menu. Chunks lives in the menu bar.
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate
        Settings.setKeyFromEnvironment()
        app.run()
    }

    // MARK: Menu bar

    /// Left click opens the menu; right click asks immediately.
    ///
    /// A single `menu` property is set once, rather than rebuilt per click, and the action
    /// is dispatched on the mouse button. Attaching a menu to a status item makes AppKit
    /// handle the click itself, so a target/action would never fire — assigning a fresh
    /// `NSMenu` and calling `performClick` inside the action is the workaround for that,
    /// and it re-enters the action, which is how the first version of this lost its icon.
    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }

        button.image = NSImage(systemSymbolName: ChunksPhase.idle.symbol,
                               accessibilityDescription: "Chunks")
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp])

        statusItem = item
        statusMenu = buildMenu()
        item.menu = statusMenu
    }

    /// Rebuild the menu. Called on click so it reflects the current phase and answer.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Every actionable item gets `target = self` explicitly.
        //
        // A menu item with `target == nil` is resolved through the responder chain. Chunks
        // is a menu-bar app: `AppShell` is not the app delegate, not a window controller,
        // and never first responder, so nothing in the chain can handle these actions and
        // they are silently dropped. The menu looked perfect and did nothing.
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        let status = NSMenuItem(title: phase.label, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        add("Ask about my screen", #selector(askNow))
        add("Ask about a region…", #selector(annotateAndAsk))
        add(Settings.voiceOutput ? "Stop speaking" : "Speak answers", #selector(toggleVoice))

        if !statusNote.isEmpty {
            let item = NSMenuItem(title: statusNote, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        add(hasPermission ? "Screen Recording: on" : "Grant Screen Recording…",
            #selector(requestPermission))
        add("Gemini key: \(KeychainStore.hasKey ? "set" : "not set")…", #selector(configureKey))
        add("Memory (\(memory.facts.count) facts)…", #selector(showMemory))

        if !points.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Pointed at", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for resolved in points {
                let item = NSMenuItem(
                    title: "↗ \(resolved.label)  (\(Int(resolved.point.x)), \(Int(resolved.point.y)))",
                    action: #selector(revealPoint(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = resolved
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        add("Quit Chunks", #selector(quit))
        return menu
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: phase.symbol,
                               accessibilityDescription: phase.label)
        button.toolTip = "Chunks — \(phase.label)"

        // Rebuilt rather than patched. The menu's contents depend on the phase, the status
        // note, the point count and the permission state, and keeping those in sync by hand
        // is how the status line ends up claiming something the app is no longer doing.
        let rebuilt = buildMenu()
        statusMenu = rebuilt
        statusItem?.menu = rebuilt
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        // Only reached when no `menu` is attached to the button. The menu is assigned in
        // `installStatusItem`, so this is the fallback path.
        if statusMenu == nil {
            statusMenu = buildMenu()
            statusItem?.menu = statusMenu
        }
    }

    /// Park the cursor where the model said to look, so the user can see that Chunks
    /// understood the screen rather than having to take its word for it.
    @objc private func revealPoint(_ sender: NSMenuItem) {
        guard let resolved = sender.representedObject as? ResolvedPoint else { return }
        // Fly, not teleport: a jump reads as a glitch, a movement reads as pointing.
        CursorAnimator.fly(to: resolved.point)
        panel.update { $0.points = $0.points }   // redraw for the highlight
    }

    @objc private func configureKey() {
        let alert = NSAlert()
        alert.messageText = "Gemini API key"
        alert.informativeText = "Stored in your login Keychain, never in a file or a plist. "
            + "Get a free key at aistudio.google.com/apikey."
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if KeychainStore.setGeminiKey(field.stringValue) {
            statusNote = "API key saved to your Keychain."
        } else {
            statusNote = "Couldn't save the API key to the Keychain."
        }
    }

    @objc private func toggleVoice() {
        Settings.voiceOutput.toggle()
        if !Settings.voiceOutput { SpeechOutput.shared.stop() }
        statusNote = Settings.voiceOutput ? "Answers will be spoken." : "Answers will be silent."
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showMemory() {
        let alert = NSAlert()
        alert.messageText = "Chunks memory"
        alert.informativeText = memory.facts.isEmpty
            ? "Nothing remembered yet."
            : memory.facts.map { "• \($0.text) (\($0.date))" }.joined(separator: "\n")
        alert.addButton(withTitle: "Open the file")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(memoryURL)
        }
    }

    var memoryURL: URL { MemoryStore.defaultURL() }

    @objc private func requestPermission() {
        CaptureEngine.requestScreenRecordingPermission()
        NSLog("[Chunks] screen recording requested — restart the app after granting")
    }

    // MARK: Hotkey

    /// Hold ⌃⌥ to ask, release to send.
    ///
    /// ⌃⌥ is two modifiers, so the signal is `flagsChanged`, not `keyDown`. An
    /// `NSEvent` global monitor is used rather than a `CGEvent` tap here: the tap is the
    /// right tool for a *listen-only* tap that must not consume events, and for a full
    /// push-to-talk pipeline with a microphone in the middle (Phase 4). For the button
    /// press that triggers a turn, the global monitor is simpler and less risky — it
    /// cannot swallow anything.
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var controlAndOptionDown = false

    /// Install both a global and a local `flagsChanged` monitor.
    ///
    /// A *global* monitor only sees events destined for other applications, so it goes
    /// deaf the moment Chunks becomes frontmost — which happens every time the status menu
    /// closes. The *local* monitor covers that gap.
    func installHotkey() {
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor in self?.evaluateHotkey(flags: event.modifierFlags) }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor in self?.evaluateHotkey(flags: event.modifierFlags) }
            return event
        }
    }

    /// Decide from the **event's own** flags, not `NSEvent.modifierFlags`.
    ///
    /// The global property is a query of current system state, read after an async hop to
    /// the main actor — by then the user may have released a key already, and the value no
    /// longer describes the transition that fired this callback. The event carries the flags
    /// as they were when it happened, which is the only race-free source.
    private func evaluateHotkey(flags: NSEvent.ModifierFlags) {
        let held = flags.contains(.control) && flags.contains(.option)
        guard held != controlAndOptionDown else { return }
        controlAndOptionDown = held

        if held {
            // Do not clobber a turn that is already running. Pressing ⌃⌥ mid-turn would
            // otherwise overwrite `.capturing`/`.thinking` with `.listening`, and the turn
            // would end up in the wrong state with the icon stuck on the microphone.
            if phase.canStartTurn { setPhase(.listening) }
        } else {
            // Release = send. The phase is `.listening` at this point, and `runTurn` accepts
            // a turn starting from there.
            Task { await runTurn(question: nil) }
        }
    }

    func uninstallHotkey() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        flagsMonitor = nil
        localFlagsMonitor = nil
    }

    // MARK: Turn

    /// The whole "explain my screen" turn, start to finish.
    func runTurn(question: String?) async {
        guard phase.canStartTurn else { return }

        guard CaptureEngine.hasScreenRecordingPermission() else {
            fail(CaptureEngine.CaptureError.notAuthorised.description)
            return
        }

        guard let display = CaptureEngine.mainDisplay() else {
            fail(CaptureEngine.CaptureError.noDisplays.description)
            return
        }

        let ask = question?.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.show(on: display) { [weak self] point in
            CursorAnimator.move(to: point)
            self?.statusNote = "Pointing at \(Int(point.x)), \(Int(point.y))."
        }
        panel.update { $0 = AnswerPanelContent(status: .working("Reading your screen…")) }

        do {
            // Marks come from the annotation overlay when the user drew something; with
            // none, this captures the whole display, which is what makes a bare hotkey
            // press useful.
            let shapes = pendingAnnotations
            pendingAnnotations = []
            setPhase(.capturing)

            let captured = try await capture.capture(display: display, shapes: shapes)
            let image = captured.composited(with: shapes, display: display)
            guard let png = ScreenCapture(image: image, globalRect: captured.globalRect).png() else {
                fail(CaptureEngine.CaptureError.emptyImage.description)
                return
            }

            setPhase(.thinking)
            panel.update { $0.status = .working("Thinking…") }

            let streamer = AnswerStreamer()
            let localRegion = display.space.localRect(fromGlobal: captured.globalRect)
            let request = TurnRequest(
                question: ask?.isEmpty == false ? ask! : "What am I looking at, and what should I do next?",
                scope: shapes.isEmpty ? .wholeScreen : .region(localRegion),
                imageData: png,
                imagePixelSize: captured.pixelSize,
                annotationNote: shapes.isEmpty ? nil : AnnotationSession(shapes: shapes).descriptionForModel,
                memoryBlock: memory.injectedBlock())

            // Stream through the parser as deltas arrive so the panel fills in as the
            // model talks, instead of appearing all at once at the end. The parser is
            // incremental by design, so the same type does the work either way.
            let answer = try await BrainGateway.shared.ask(request) { delta in
                let partial = streamer.displayable
                Task { @MainActor in
                    self.panel.update {
                        $0.status = .working("Answering…")
                        $0.speech = partial.speech
                        $0.detail = partial.detail
                        $0.isStreaming = true
                    }
                }
            }
            streamer.finish()
            let final = Answer(
                spokenText: answer.spokenText,
                detailText: answer.detailText,
                points: answer.points,
                proposal: answer.proposal)

            // Resolve the model's pixel coordinates against the crop it actually saw.
            let resolved = final.points.map { target in
                ResolvedPoint(
                    point: captured.globalPoint(forImagePixelX: target.x, target.y),
                    label: target.label,
                    imagePixel: LogicalPoint(x: target.x, y: target.y))
            }

            setPhase(.speaking)
            transcript = final.spokenText
            points = resolved
            applyMemory(final.proposal)
            lastCapture = captured

            panel.update {
                $0.status = .ready
                $0.speech = final.spokenText
                $0.detail = final.detailText
                $0.points = resolved.map {
                    PanelPoint(label: $0.label, point: $0.point, imagePixel: $0.imagePixel)
                }
                $0.isStreaming = false
            }
            speak(final.spokenText)
            setPhase(.idle)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Read the answer aloud, if voice output is on.
    private func speak(_ text: String) {
        guard Settings.voiceOutput, !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        SpeechOutput.shared.speak(utterance)
    }

    private func applyMemory(_ proposal: MemoryProposal?) {
        guard let proposal else { return }
        for addition in proposal.add {
            let outcome = memory.propose(section: addition.section, text: addition.fact)
            if case .rejectedAsSecret(let reason) = outcome {
                statusNote = "Not remembering that — it \(reason)."
            }
        }
        for prune in proposal.prune { memory.remove(matching: prune) }
        if memory.isFull { statusNote = "Memory is full — open it (⌘M) to prune something." }
    }

    private func fail(_ message: String) {
        transcript = message
        statusNote = ""
        // The panel stays up on failure. A turn that dies silently, with the card
        // disappearing, is indistinguishable from the app not working at all.
        panel.update { content in
            content.status = .failed(message)
            content.isStreaming = false
        }
        setPhase(.idle)
    }

    @objc private func askNow() {
        Task { await runTurn(question: nil) }
    }

    /// Open the annotation overlay, so the user can circle something and ask about it.
    @objc private func annotateAndAsk() {
        guard CaptureEngine.hasScreenRecordingPermission() else {
            statusNote = CaptureEngine.CaptureError.notAuthorised.description
            refreshIcon()
            return
        }
        guard let display = CaptureEngine.mainDisplay() else { return }

        let overlay = AnnotationOverlayWindow(display: display) { [weak self] shapes in
            guard let self else { return }
            self.pendingAnnotations = shapes
            self.statusNote = shapes.isEmpty ? "" : "Region marked."
            self.refreshIcon()
            Task { await self.runTurn(question: nil) }
        }
        overlay.show()
    }

    private func setPhase(_ newPhase: ChunksPhase) {
        phase = newPhase
        // Returning to idle also clears the hotkey's latched state. If a `flagsChanged`
        // event is ever missed — the app launching while ⌃⌥ is already held, or a monitor
        // tearing down — the latch would stay set and the next real press would be read as a
        // release, starting a turn nobody asked for.
        if newPhase == .idle { controlAndOptionDown = false }
        refreshIcon()
    }

    func checkPermission() {
        hasPermission = CaptureEngine.hasScreenRecordingPermission()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let shell = AppShell.shared
        shell.installStatusItem()
        shell.installHotkey()
        shell.checkPermission()
        NSLog("[Chunks] launched. Screen recording: %@. Displays: %d.",
              CaptureEngine.hasScreenRecordingPermission() ? "granted" : "NOT granted",
              CaptureEngine.displays().count)
        for display in CaptureEngine.displays() {
            NSLog("[Chunks]   display %u main=%@ bounds=%.0fx%.0f scale=%.1fx",
                  display.displayID, display.isMain ? "yes" : "no",
                  display.frame.width, display.frame.height, display.backingScale)
        }
    }
}

// MARK: - Bridge

/// Calls the configured brain, walking the model fallback chain on contention.
final class BrainGateway {
    static let shared = BrainGateway()
    private init() {}

    func ask(_ request: TurnRequest,
             onDelta: @escaping (String) -> Void = { _ in }) async throws -> Answer {
        let key = try KeychainStore.geminiKey()
        let registry = ProviderRegistry()
        let (chain, warning) = registry.resolve(provider: ProviderRegistry.gemini,
                                                preferred: Settings.preferredModel,
                                                needsVision: request.needsVision)
        guard !chain.isEmpty else { throw ChunksError.noCapableModel(warning ?? "No model available.") }

        let session = URLSession(configuration: .ephemeral)
        let limiter = RateLimiter()
        var lastError: Error?

        // Labelled because `fallBackToNextModel` must leave the *inner* loop. A bare
        // `break` inside a `switch` exits the switch, not the loop, so the model we just
        // gave up on would be tried again three more times — the exact opposite of what
        // the retry policy decided.
        modelLoop: for model in chain {
            for attempt in 0..<3 {
                let wait = limiter.delayUntilAvailable()
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                limiter.consume()

                do {
                    let text = try await Self.perform(session: session, key: key, model: model,
                                                     request: request, onDelta: onDelta)
                    return Self.interpret(text)
                } catch {
                    lastError = error
                    switch RetryPolicy.decide(for: Self.classify(error), attempt: attempt) {
                    case .retrySameModel(let after):
                        try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                    case .fallBackToNextModel:
                        continue modelLoop
                    case .fail:
                        throw error
                    }
                }
            }
        }
        throw lastError ?? ChunksError.noCapableModel("All models failed.")
    }

    private static func perform(session: URLSession, key: String,
                                model: BrainModel, request: TurnRequest,
                                onDelta: @escaping (String) -> Void) async throws -> String {
        var url = ProviderRegistry.geminiBase.appendingPathComponent("interactions")
        url = URL(string: "\(url.absoluteString)?alt=sse")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(GeminiRequestBuilder.apiRevision, forHTTPHeaderField: "Api-Revision")
        req.httpBody = try GeminiRequestBuilder.encode(model: model.id, request: request, stream: true)
        req.timeoutInterval = 90

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ChunksError.transport("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Read the body even on failure. Without it a 400 arrives as "The request was
            // rejected: " with nothing after the colon, which is the least useful error
            // message there is — the server usually names the exact field it disliked, and
            // that is the only way to find out what was wrong.
            var body = ""
            do {
                for try await line in bytes.lines { body += line + "\n" }
            } catch {
                body = "<body unreadable: \(error.localizedDescription)>"
            }
            throw ChunksError.http(statusCode: http.statusCode, body: body)
        }

        var text = ""
        for try await line in bytes.lines {
            for event in GeminiStreamParser.parse(line: String(line)) {
                if case .textDelta(let delta) = event {
                    text += delta
                    onDelta(delta)
                }
            }
        }
        return text
    }

    private static func classify(_ error: Error) -> RetryPolicy.Failure {
        if let chunksError = error as? ChunksError {
            switch chunksError {
            case .http(let code, let body):
                return RetryPolicy.classify(statusCode: code, body: body)
            default:
                return .unknown(statusCode: nil, detail: chunksError.description)
            }
        }
        return RetryPolicy.classify(error: error)
    }

    /// Run the raw reply through `ResponseParser`.
    ///
    /// Delegates to `AnswerStreamer` rather than walking the events a second time. This
    /// used to have its own loop with its own opinion about which events are speech, and
    /// the two paths disagreed: `ResponseParser` emits `<SAY>` content as **both**
    /// `.speech` and `.text` (spoken and also written to the transcript), so this version
    /// put every spoken sentence into the detail pane a second time. One implementation,
    /// one answer.
    static func interpret(_ raw: String) -> Answer {
        let streamer = AnswerStreamer()
        streamer.push(raw)
        let result = streamer.displayable

        return Answer(
            spokenText: result.speech.isEmpty ? result.detail : result.speech,
            detailText: result.speech.isEmpty ? "" : result.detail,
            points: streamer.points,
            proposal: streamer.proposal)
    }
}

/// A reply, split into the part to speak and the part to show alongside it.
struct Answer: Equatable {
    var spokenText: String
    var detailText: String
    var points: [PointTarget]
    var proposal: MemoryProposal?

    /// A reply with no `<SAY>` at all: show the text, speak nothing.
    var hasSpeech: Bool { !spokenText.isEmpty }
    var isEmpty: Bool { spokenText.isEmpty && detailText.isEmpty }
}

/// A point the model identified, resolved onto the real screen.
struct ResolvedPoint: Equatable {
    /// Global logical coordinates — directly usable for a cursor move.
    let point: LogicalPoint
    let label: String
    /// Pixel within the image the model was shown, kept for the panel so the mapping
    /// stays checkable by eye.
    let imagePixel: LogicalPoint
}

enum ChunksError: Error, CustomStringConvertible {
    case noCapableModel(String)
    /// An HTTP failure, with the server's explanation attached.
    ///
    /// The body is part of the error, not decoration. Gemini's 400s name the offending
    /// field, and a bare status code sends you guessing.
    case http(statusCode: Int, body: String)
    case transport(String)
    case missingKey
    case keychain(OSStatus)

    var description: String {
        switch self {
        case .noCapableModel(let message): return message
        case .http(let code, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = RetryPolicy.userFacingMessage(
                for: RetryPolicy.classify(statusCode: code, body: detail))
            return detail.isEmpty ? summary : "\(summary) — server said: \(detail.prefix(400))"
        case .transport(let detail):
            return "Couldn't reach the model: \(detail)"
        case .missingKey:
            return "No Gemini API key set. Add one in Settings."
        case .keychain(let status):
            // `errSecMissingEntitlement` is the usual one for an unsigned/ad-hoc app.
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Could not read the API key from the Keychain: \(detail)."
        }
    }
}

// MARK: - Support

final class Settings {
    static var preferredModel: String? {
        get { UserDefaults.standard.string(forKey: "preferredModel") }
        set { UserDefaults.standard.set(newValue, forKey: "preferredModel") }
    }

    /// Whether answers are spoken. Off is a legitimate choice: a user who already has a
    /// screen reader, or who shares a room, needs the answer without audio.
    static var voiceOutput: Bool {
        get {
            // Default on, because a companion you have to read is a companion you cannot
            // glance at. `object(forKey:)` rather than `bool(forKey:)` so a first run is
            // distinguishable from an explicit "off".
            UserDefaults.standard.object(forKey: "voiceOutput") as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "voiceOutput") }
    }

    /// Set the key non-interactively, for first-run setup scripts.
    static func setKeyFromEnvironment() {
        guard let key = ProcessInfo.processInfo.environment["CHUNKS_GEMINI_KEY"],
              !key.isEmpty else { return }
        if KeychainStore.setGeminiKey(key) {
            NSLog("[Chunks] API key loaded from the CHUNKS_GEMINI_KEY environment variable")
        }
    }
}

// MARK: - Annotation overlay

/// A transparent, click-through-until-touched window over one display for drawing a region.
///
/// `.nonactivatingPanel` is load-bearing. A regular `NSWindow` would take focus the moment
/// it appeared, and the user would lose their place — the exact "focus stealing" behaviour
/// Chunks is required never to do. A non-activating panel takes clicks without ever
/// becoming the key window, so the app the user was reading keeps its keyboard focus.
final class AnnotationOverlayWindow: NSObject, NSWindowDelegate {

    private let display: DisplayInfo
    private let onSubmit: ([AnnotationShape]) -> Void
    private var window: NSPanel?
    private let canvas = AnnotationCanvas()

    init(display: DisplayInfo, onSubmit: @escaping ([AnnotationShape]) -> Void) {
        self.display = display
        self.onSubmit = onSubmit
        super.init()
    }

    func show() {
        let frame = NSRect(x: display.frame.minX, y: display.frame.minY,
                           width: display.frame.width, height: display.frame.height)

        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        // Above everything, but never key: the user's frontmost app keeps focus.
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = canvas
        panel.acceptsMouseMovedEvents = true

        canvas.frame = frame
        canvas.onSubmit = { [weak self] shapes in self?.submit(shapes) }
        canvas.onCancel = { [weak self] in self?.cancel() }

        window = panel
        panel.orderFrontRegardless()
        panel.makeFirstResponder(canvas)
    }

    private func submit(_ shapes: [AnnotationShape]) {
        close()
        onSubmit(shapes)
    }

    private func cancel() { close() }

    private func close() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }

    func windowWillClose(_ notification: Notification) { close() }
}

/// The drawing surface: freehand, ellipse, rect, arrow, plus undo and submit.
final class AnnotationCanvas: NSView {

    var onSubmit: (([AnnotationShape]) -> Void)?
    var onCancel: (() -> Void)?

    private var session = AnnotationSession()
    private var activePoints: [LogicalPoint] = []
    private var dragStart: LogicalPoint?
    private var tool: Tool = .pen

    /// Undo is hand-rolled over `AnnotationSession.undo()` rather than using
    /// `NSUndoManager`. The only undoable action is "remove the last mark", and
    /// `NSUndoManager` requires a window's responder chain to be wired up first — which a
    /// non-activating panel deliberately does not participate in.
    private func undoLast() {
        session.undo()
        needsDisplay = true
    }

    enum Tool: String, CaseIterable {
        case pen = "Pen"
        case ellipse = "Circle"
        case rect = "Box"
        case arrow = "Arrow"

        var symbol: String {
            switch self {
            case .pen: return "scribble.variable"
            case .ellipse: return "circle"
            case .rect: return "rectangle"
            case .arrow: return "arrow.up.right"
            }
        }
    }

    private enum DragPhase { case drawing, choosingTool }

    private var dragPhase: DragPhase = .drawing

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    // MARK: Drawing

    private func localPoint(_ event: NSEvent) -> LogicalPoint {
        // The view is flipped, so `convert` gives top-left-origin coordinates that match
        // `LogicalPoint`'s convention directly. No y-flipping anywhere else.
        let p = convert(event.locationInWindow, from: nil)
        return LogicalPoint(x: Double(p.x), y: Double(p.y))
    }

    override func mouseDown(with event: NSEvent) {
        let point = localPoint(event)
        dragStart = point

        // A second click commits the shape, matching how every drawing tool behaves.
        if dragPhase == .choosingTool {
            dragPhase = .drawing
            activePoints = []
            dragStart = nil
            return
        }
        activePoints = [point]
    }

    override func mouseDragged(with event: NSEvent) {
        let point = localPoint(event)
        switch tool {
        case .pen:
            activePoints.append(point)
        case .ellipse, .rect, .arrow:
            break  // Derived from dragStart to the current point at draw time.
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = localPoint(event)
        guard let start = dragStart else { return }
        dragStart = nil

        let shape: AnnotationShape?
        switch tool {
        case .pen:
            activePoints.append(point)
            shape = activePoints.count >= 2 ? .stroke(activePoints) : nil
        case .ellipse:
            let centre = LogicalPoint(x: (start.x + point.x) / 2, y: (start.y + point.y) / 2)
            let rx = abs(point.x - start.x) / 2
            let ry = abs(point.y - start.y) / 2
            shape = rx > 2 && ry > 2 ? .ellipse(center: centre, radiusX: rx, radiusY: ry) : nil
        case .rect:
            let rect = LogicalRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                   width: abs(point.x - start.x), height: abs(point.y - start.y))
            shape = rect.width > 4 && rect.height > 4 ? .rect(rect) : nil
        case .arrow:
            let distance = hypot(point.x - start.x, point.y - start.y)
            shape = distance > 6 ? .arrow(from: start, to: point) : nil
        }

        if let shape {
            session.add(shape)
        }
        activePoints = []
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let colour = AnnotationShape.overlayStrokeColor
        NSColor(cgColor: colour)?.setStroke()
        NSColor(cgColor: colour)?.setFill()
        let line = NSBezierPath()
        line.lineWidth = AnnotationShape.strokeWidth
        line.lineCapStyle = .round
        line.lineJoinStyle = .round

        // The in-progress shape is drawn last so a mark being dragged is always on top.
        var drawable = session.shapes
        if let pending = inProgressShape() { drawable.append(pending) }

        for shape in drawable {
            guard let path = Self.bezier(for: shape) else { continue }
            path.lineWidth = line.lineWidth
            path.lineCapStyle = line.lineCapStyle
            path.lineJoinStyle = line.lineJoinStyle
            path.stroke()
        }
    }

    private func inProgressShape() -> AnnotationShape? {
        guard let start = dragStart else {
            return activePoints.count >= 2 ? .stroke(activePoints) : nil
        }
        let end = activePoints.last ?? start
        switch tool {
        case .pen: return activePoints.count >= 2 ? .stroke(activePoints) : nil
        case .arrow: return .arrow(from: start, to: end)
        case .rect:
            return .rect(LogicalRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                     width: abs(end.x - start.x), height: abs(end.y - start.y)))
        case .ellipse:
            return .ellipse(center: LogicalPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2),
                            radiusX: abs(end.x - start.x) / 2, radiusY: abs(end.y - start.y) / 2)
        }
    }

    /// The view-space path for a mark. Separate from `AnnotationShape.boundingBox` so the
    /// pure logic stays free of AppKit and unit-testable.
    ///
    /// The view is flipped, so its y axis already matches `LogicalPoint`. Drawing a shape
    /// here and compositing the same shape into a screenshot share this convention, which
    /// is why the user sees the circle where they drew it rather than mirrored vertically.
    static func bezier(for shape: AnnotationShape) -> NSBezierPath? {
        let path = NSBezierPath()
        switch shape {
        case .stroke(let points):
            guard let first = points.first else { return nil }
            path.move(to: CGPoint(x: first.x, y: first.y))
            for p in points.dropFirst() { path.line(to: CGPoint(x: p.x, y: p.y)) }
        case .ellipse(let centre, let rx, let ry):
            path.appendOval(in: NSRect(x: centre.x - rx, y: centre.y - ry,
                                       width: rx * 2, height: ry * 2))
        case .rect(let r):
            path.appendRect(NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height))
        case .arrow(let from, let to):
            let head: CGFloat = 12
            let angle = atan2(to.y - from.y, to.x - from.x)
            path.move(to: CGPoint(x: from.x, y: from.y))
            path.line(to: CGPoint(x: to.x, y: to.y))
            path.move(to: CGPoint(x: to.x, y: to.y))
            path.line(to: CGPoint(x: to.x - head * cos(angle - .pi / 7),
                                  y: to.y - head * sin(angle - .pi / 7)))
            path.line(to: CGPoint(x: to.x - head * cos(angle + .pi / 7),
                                  y: to.y - head * sin(angle + .pi / 7)))
            path.close()
        }
        return path
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:                                   // Return, Enter
            onSubmit?(session.shapes)
        case 53:                                        // Escape
            onCancel?()
        case 51, 115:                                   // Backspace, forward delete
            undoLast()
        case 49:                                        // Space: cycle tool
            let all = Tool.allCases
            let index = all.firstIndex(of: tool) ?? 0
            tool = all[(index + 1) % all.count]
            updateHint("Tool: \(tool.rawValue) · Return to ask · Esc to cancel")
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    private lazy var toolHint: NSTextField? = {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        field.textColor = .white
        field.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        field.alignment = .center
        field.isBezeled = false
        return field
    }()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let hint = toolHint else { return }
        addSubview(hint)
        hint.frame = NSRect(x: bounds.midX - 220, y: 14, width: 440, height: 26)
        updateHint("Circle or draw over what you want explained · Return to ask · Esc to cancel")
    }

    private func updateHint(_ text: String) {
        toolHint?.stringValue = text
    }
}

/// The Gemini API key, in the login Keychain.
///
/// Not in `UserDefaults`, and not in a file. `UserDefaults` lands in a plist inside the
/// app bundle that is readable by anything running as the user, is captured by ordinary
/// unencrypted backups, and shows up in `defaults read` — for a credential, that is not an
/// acceptable store. The project already refuses to write credential-shaped text into
/// memory; keeping the key out of plists is the same principle applied to configuration.
///
/// `kSecAttrAccessibleWhenUnlocked` rather than the `Always` variants: the key is only
/// needed while the user is at the machine asking a question, and an item readable from a
/// locked machine is a liability with no benefit here.
enum KeychainStore {
    private static let service = "app.chunks.mac"
    private static let account = "gemini-api-key"

    static func geminiKey() throws -> String {
        // An empty stored value is treated as absent: a Keychain item can outlive the app
        // that wrote it, and an empty key would otherwise become a 401 the user cannot
        // explain.
        guard let key = try read(), !key.isEmpty else { throw ChunksError.missingKey }
        return key
    }

    static var hasKey: Bool {
        // `read()` already maps `errSecItemNotFound` to nil, so a successful call means
        // the key is present and a thrown one means the Keychain itself is unreachable.
        // The latter must not be reported as "no key set" — that sends the user to add a
        // key they already added, while the real problem is an entitlement or lock state.
        (try? read()) != nil
    }

    @discardableResult
    static func setGeminiKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private static func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw ChunksError.keychain(status)
        }
    }
}
