import AppKit
import ChunksKit
import Foundation

/// `--probe-protocol` — five fixed turns against the production prompt, asserting each tag family
/// still arrives.
///
/// A prompt change that quietly stops the model using a tag is a feature regression with no failing
/// test: the parser still parses `[ACT:…]` perfectly, the model just never writes one. The unit
/// suite builds tags by hand, so it cannot see this; only a real model answering a real turn can.
/// These five turns are the five families the product runs on — press, remind, type, plain speech
/// with a completion line, and scroll — and the probe exits non-zero when any family goes missing.
@MainActor
enum ProtocolProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe-protocol") }

    private static func out(_ line: String) {
        print(line)
        Log.write(line)
    }

    private struct Turn {
        let question: String
        let expects: String
        let check: (AnswerStreamer) -> Bool
    }

    /// Whether this Mac is showing the login window rather than his desktop.
    ///
    /// Measured 2026-10-31, three separate runs of this probe: two turns came back *"it looks like
    /// your mac is at the login screen"* and I read that as the model inventing an excuse for a
    /// correct refusal. Recording the frontmost app beside the verdict said otherwise — the capture
    /// really was `loginwindow`, because a probe run from a shell keeps going while he is away from
    /// the machine. A locked screen is not a prompt regression and it is not a pass either: every
    /// one of these five turns asks about something on the desktop, so the honest answer is that the
    /// run measured nothing.
    private static func screenIsLocked() -> Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        return front == "loginwindow" || front == "WindowServer"
    }

    /// A control the press turn can honestly be aimed at, read out of the tree as it is *then*.
    ///
    /// The turn used to ask "click the send button for me" and require an `[ACT:]` back. Measured
    /// 2026-10-31 with the capture recorded beside the verdict: the reply was *"there is no send
    /// button here, just a textedit file picker window"* — the correct refusal of a control that was
    /// not on the screen, graded as a prompt regression. A fixture the machine is not showing cannot
    /// test a tag family; it can only force the model to invent one to pass. So the probe names a
    /// control the app is actually publishing, the way it already opens TextEdit to give the type
    /// turn a field. Menu rows are skipped: they are on the display and are the one thing the press
    /// routes refuse by name.
    private static func pressFixture() -> String? {
        // The app the probe just opened is the fallback, not another guess at his screen: TextEdit's
        // panel publishes `New Document` and `Show Options` as real titled buttons, whereas the
        // frontmost app here (Qoder) publishes 227 pressable controls whose every title is empty and
        // whose words live in child text — the exact shape the ranking exists for, and a shape this
        // probe cannot name out loud.
        let apps = [NSWorkspace.shared.frontmostApplication?.localizedName, "TextEdit"]
            .compactMap { $0 }
        let display = CGDisplayBounds(CGMainDisplayID())
        for app in apps {
            let controls = AXTDriver.pressableControls(ownedByNamed: app).controls
            // A plain button first: `Where:` is a titled control the hit test answers, and a card
            // that says "click the Where: for me" measures the press family on a pop-up nobody
            // would ever ask for.
            for pass in 0...1 {
                for control in controls {
                    let role = control.info.role ?? ""
                    if pass == 0, role != "AXButton" { continue }
                    if role == "AXMenuItem" || role == "AXMenuBarItem" || role == "AXMenu" { continue }
                    let title = (control.info.title ?? "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t:"))
                    guard title.count >= 3, title.count <= 40 else { continue }
                    guard let frame = control.info.frame, frame.width > 1, frame.height > 1,
                          display.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
                    return title
                }
            }
        }
        return nil
    }

    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        let turns: [Turn] = [
            Turn(question: "click the send button for me", expects: "<SAY> and [ACT:]") { streamer in
                !streamer.displayable.speech.isEmpty
                    && streamer.actionRequests.contains { $0.verb == .press }
            },
            Turn(question: "in ten minutes remind me to stretch", expects: "[DO:remind:]") { streamer in
                streamer.toolRequests.contains { if case .addReminder = $0 { return true }; return false }
            },
            Turn(question: "type the words good night into that open document window",
                 expects: "[TYPE:]") { streamer in
                streamer.actionRequests.contains { if case .type = $0.verb { return true }; return false }
            },
            Turn(question: "what is on my screen right now? answer in one sentence",
                 expects: "<SAY> and <SUMMARY>") { streamer in
                !streamer.displayable.speech.isEmpty && streamer.summary != nil
            },
            Turn(question: "scroll down until you find the invoice", expects: "[SCROLL:] or the honest retraction") { streamer in
                streamer.actionRequests.contains { if case .scroll = $0.verb { return true }; return false }
                    || streamer.displayable.speech == AnswerStreamer.retractionLine
            },
        ]

        Task { @MainActor in
            guard let display = CaptureEngine.mainDisplay() else {
                out("protocol: FAIL — no display to capture")
                Log.flush()
                exit(1)
            }
            if screenIsLocked() {
                out("protocol: NOTHING MEASURED — the display is asleep or at the login window, "
                    + "so every turn here would be graded on a screen that shows nothing. "
                    + "Unlock the Mac and run it again.")
                Log.flush()
                exit(3)
            }
            let prompt = CompanionManager.companionVoiceResponseSystemPrompt
                + "\n\n" + CompanionManager.actingRules(askBeforeActing: false)
            out("protocol: prompt under test is \(prompt.count) chars (~\(prompt.count / 4) tokens)")
            // The TYPE family needs an editable field on screen, and his desktop usually has none
            // open — on the first run the model correctly asked "which chat?" instead of typing
            // into nothing, which is the right behaviour and the wrong fixture. An empty TextEdit
            // document is the probe's own fixture, the way the render probes build their own cards.
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/TextEdit.app"))
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            let pressName = pressFixture()
            var failures = 0
            var skips = 0
            for (index, turn) in turns.enumerated() {
                // The press turn's question is rewritten against the live tree; the other four are
                // fixed sentences, because what they test is the prompt, not the screen.
                if index == 0, pressName == nil {
                    out("protocol: turn 1 SKIPPED — no named, on-screen, pressable control to aim at; "
                        + "asking for a control that is not there tests the model's willingness to "
                        + "invent one, not the prompt")
                    skips += 1
                    continue
                }
                let question = (index == 0 ? pressName : nil).map { "click the \($0) for me" }
                    ?? turn.question
                do {
                    let captured = try await CaptureEngine().capture(display: display, shapes: [])
                    let image = captured.composited(with: [], display: display)
                    // Recorded with the verdict, because a FAIL can mean two opposite things. Measured
                    // 2026-10-31: two turns came back "i cannot see a send button, it looks like your
                    // mac is at the login screen" — a correct refusal of a control that was not on the
                    // screen, blamed on a screen that was there. Only the capture behind it can tell
                    // a prompt regression apart from a fixture the machine was not showing.
                    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
                    let asleep = CGDisplayIsAsleep(display.displayID) != 0
                    let screenNote = "screen: \(front), \(captured.pixelSize.width)x\(captured.pixelSize.height)px"
                        + (asleep ? " — DISPLAY ASLEEP" : "")
                    guard let png = ScreenCapture(image: image, globalRect: captured.globalRect).png() else {
                        out("protocol: turn \(index + 1) FAIL — could not encode the screen")
                        failures += 1
                        continue
                    }
                    let response = try await BrainGateway().analyzeImageStreaming(
                        images: [(data: png,
                                  label: "The user's whole screen "
                                        + "(\(captured.pixelSize.width)x\(captured.pixelSize.height) pixels)")],
                        systemPrompt: prompt,
                        userPrompt: question,
                        onTextChunk: { _ in })
                    let streamer = AnswerStreamer()
                    streamer.push(response.text)
                    streamer.finish()
                    // The same guard the live pipeline applies, so the probe measures the turn as
                    // the user would experience it — a retraction is an honest outcome, the raw
                    // promise is not.
                    streamer.retractUnbackedPromises()
                    if turn.check(streamer) {
                        out("protocol: turn \(index + 1) PASS — \(turn.expects) emitted "
                            + "(\(String(format: "%.1f", response.duration))s)")
                    } else {
                        failures += 1
                        out("protocol: turn \(index + 1) FAIL — expected \(turn.expects); \(screenNote); "
                            + "reply was: \(response.text.prefix(240))")
                    }
                } catch {
                    // A model that will not answer is not a prompt that regressed, and one
                    // contended window must not zero a whole run: the turn is recorded as skipped
                    // and the rest still get their measurement.
                    skips += 1
                    out("protocol: turn \(index + 1) SKIPPED — the request went out and nothing "
                        + "answered it: \(error)")
                }
            }
            let measured = turns.count - skips
            if failures > 0 {
                out("protocol: \(failures) of \(turns.count) turns lost a tag family")
            } else if skips > 0 {
                // "0 of 5 measured, all passed" is the sentence this repo exists to refuse: a run
                // that checked nothing must not read like a run that passed.
                out(measured == 0
                    ? "protocol: NOTHING MEASURED — all \(turns.count) turns were skipped by the "
                      + "network or the model; no tag family was checked on this run"
                    : "protocol: \(measured) of \(turns.count) turns measured, all passed; "
                      + "\(skips) skipped by contention — re-run for the rest")
            } else {
                out("protocol: all \(turns.count) turns emitted their tags on the dieted prompt")
            }
            Log.flush()
            exit(failures > 0 ? 1 : (skips > 0 ? 3 : 0))
        }
        RunLoop.main.run()
    }
}
