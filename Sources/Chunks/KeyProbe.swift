import AppKit
import ChunksKit
import Foundation

/// `--probe-keys [AppName]` — what the keyboard route would do, and where it would land.
///
/// The read-only half of 3.10, and the reason it exists is the shape of the act itself. A press
/// leaves a pointer where it happened; `[POINT:]` can be re-aimed and a card can quote the control
/// the hit test found. A keystroke leaves **nothing you can see** — it goes to whatever holds the
/// focus, which for an Electron editor is a fact the app does not publish at all. So the question
/// "where would that have gone?" has no answer in the crash report, no answer on the card, and no
/// answer in a screenshot. It needs a door of its own.
///
/// Nothing here posts an event. It reads the table, the classification and the live focus, and says
/// plainly which of the three it could not answer — because a probe that quietly reports "unknown"
/// as though it were a result is how this project has been misled about its own machine before.
enum KeyProbe {

    static var isRequested: Bool { CommandLine.arguments.contains("--probe-keys") }

    /// The expressions the prompt names, so what is checked is what a model is told it may write.
    private static let vocabulary = [
        "a", "return", "space", "backspace", "backspace x10", "delete", "escape",
        "tab", "left", "home", "end", "pageup", "pagedown", "f5", "f12",
        "shift+down x5", "option+right", "command+s", "command+shift+p", "command+n",
        "ctrl+c", "command+q", "command+option+escape", "capslock",
        "cmd", "cmd++", "excel", "hypnotic", "backspace x0",
    ]

    @MainActor
    static func start() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let nonce = "KEYS-\(ProcessInfo.processInfo.processIdentifier)-"
            + "\(Int(Date().timeIntervalSince1970))"
        print("nonce: \(nonce)")
        print("keys probe — nothing is posted by this mode\n")

        var routine = 0, command = 0, refused = 0, unreadable = 0
        for body in vocabulary {
            guard let combo = KeyAction.parse(body) else {
                unreadable += 1
                print("  unreadable : \(body)")
                continue
            }
            let kind = KeyAction.classify(combo, focusedRole: nil)
            switch kind {
            case .routine: routine += 1
            case .command: command += 1
            case .refused(let reason):
                refused += 1
                print("  refused : \(combo.display) — \(reason.prefix(70))")
                continue
            }
            let bits = KeyAction.eventFlags(for: combo)
            print("  \(kind == .routine ? "routine" : "asked  "): "
                  + "\(combo.display) → key \(combo.keyCode) flags 0x"
                  + String(bits, radix: 16, uppercase: false)
                  + " ×\(combo.times)")
        }
        print("\n  \(routine) routine, \(command) asked, \(refused) refused, \(unreadable) unreadable")

        // The two refusals that must never be reachable by a routine reading of the table.
        expect(KeyAction.parse("command+q").map {
            if case .refused = KeyAction.classify($0, focusedRole: nil) { return true }
            return false
        } == true, "command+q must stay refused while quitting has its own always-asked verb")
        expect(KeyAction.parse("capslock").map {
            if case .refused = KeyAction.classify($0, focusedRole: nil) { return true }
            return false
        } == true, "caps lock is a keyboard-wide switch and has no undo")
        expect(KeyAction.parse("backspace x100000")?.times == KeyAction.maxRepeat,
               "a repetition must be bounded, or one tag is a freeze with a voice attached")

        // Both halves of the prompt, from the same function the live request splices. His switch is
        // his to set and this probe does not write his settings, so the check reads both branches
        // rather than whichever one this machine happens to be under: the asking-on half has to teach
        // the tag and name the three refusals, the asking-off half has to say the keyboard is
        // unavailable in the same breath as the tag it refuses. A silent branch is either a
        // capability no model can ask for, or a promise this build will not keep.
        let askingOn = CompanionManager.actingRules(askBeforeActing: true)
        let askingOff = CompanionManager.actingRules(askBeforeActing: false)
        expect(askingOn.contains("[DO:key:") && askingOn.contains("command+option+escape")
               && askingOn.contains("command+q") && !askingOn.contains("keyboard is NOT available"),
               "with asking on, the prompt must teach [DO:key:…] and name what it will not press")
        expect(askingOff.contains("keyboard is NOT available") && !askingOff.contains("[DO:key:App|"),
               "with asking off, the prompt must refuse the keyboard rather than offer it")
        print("  prompt: both branches say what the switch they describe does")

        guard let name = appNameRequested() else {
            print("\n  (pass an app name to see where a key would land: --probe-keys Terminal)")
            Log.flush()
            exit(0)
        }
        reportFocus(named: name)
        Log.flush()
        exit(0)
    }

    /// Which application would receive a keystroke right now, and what it says is focused.
    @MainActor
    private static func reportFocus(named name: String) {
        guard let app = ToolRunner.runningApplication(named: name) else {
            print("\n  \(name): not running. A key act is refused rather than launched — "
                  + "opening an app is a different yes.")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            == app.processIdentifier
        print("\n  \(name): pid \(app.processIdentifier), "
              + (front ? "frontmost" : "NOT frontmost — a key act would raise it first, and "
                        + "refuse if that failed. Its focus is read below while it is in the "
                        + "background, which many apps answer with nothing at all; that is not the "
                        + "same claim as \"it never answers\"."))
        let focus = AXTDriver.keyFocus(pid: Int(app.processIdentifier))
        if focus.answered {
            print("  focus: \(focus.display) (role \(focus.role ?? "nil"))")
            // The one classification that changes meaning with the role: the same Return is a
            // newline in a text area and a submission in a one-line field, and he should be able to
            // see which one he is about to get before he asks for it.
            let enter = KeyAction.parse("return")
            if let combo = enter {
                let kind = KeyAction.classify(combo, focusedRole: focus.role)
                print("  a `return` there is " + (kind == .routine
                      ? "a newline"
                      : "asked about — it may submit"))
            }
        } else {
            // The Electron answer, and the honest one: this is why the target of a key act is the
            // app, and why the switch is what protects him rather than a quoted control name.
            print("  focus: the app does not answer `AXFocusedUIElement` — so a key lands wherever "
                  + "its own caret is, and the card can only name the application.")
        }
    }

    private static func appNameRequested() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-keys"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let name = CommandLine.arguments[index + 1]
        return name.hasPrefix("-") ? nil : name
    }

    private static func expect(_ condition: Bool, _ why: String) {
        if condition { return }
        print("  FAIL: \(why)")
        Log.flush()
        exit(1)
    }
}
