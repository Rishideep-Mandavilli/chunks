import AppKit
import ChunksKit
import SwiftUI

/// `Chunks --probe-hover` — does a click over the card survive?
///
/// Four crash reports in eighteen hours share the same five frames at the top: `swift_getObjectType`
/// ← `swift_task_isMainExecutorImpl` ← `MainActor.assumeIsolated` ← a SwiftUI event binding. The
/// bottom differs, and that difference is the finding: two came in through `NSHostingView.mouseEntered`
/// → `HoverEventDispatcher`, one through `NSHostingView.mouseDown` → `UpdateGroup.dispatchActions` →
/// `_ButtonGesture`. So it is **not** the hover feature — it is SwiftUI's event machinery as such, and
/// deleting `.onHover` would not close it. What all three have in common is AppKit delivering a mouse
/// event to one of this app's SwiftUI surfaces while the assertion about the main actor faults.
///
/// The probe therefore does the ordinary thing that kills it: build the surface in a real window and
/// hand AppKit a left-button-down over the middle of it through `NSApp.sendEvent`, which is the route
/// the crash report shows (`_handleLeftMouseDownEvent:` → `sendEvent:` → `NSHostingView`).
///
/// `--probe-hover --minimal` builds a card of nothing but a text and two buttons, in the same build and
/// the same window. That fork decides where the fault lives: if the minimal surface survives and the
/// real one faults, the trigger is inside our view tree; if both fault, it is the build or the runtime,
/// and no view change will help.
///
/// A crash here is the bug reproduced: 139 means the path is open, 0 means it is closed. The event goes
/// to Chunks' own window inside this process — the pointer does not move and no other app is touched.
@MainActor
enum HoverProbe {

    static var isRequested: Bool { CommandLine.arguments.contains("--probe-hover") }

    /// The trivial surface, for the fork described above.
    private static var minimalSurfaceRequested: Bool { CommandLine.arguments.contains("--minimal") }

    /// Host the surface in the panel class the real card uses, rather than a plain window.
    private static var panelSurfaceRequested: Bool { CommandLine.arguments.contains("--panel") }

    static func start() -> Never {
        guard Thread.isMainThread else {
            print("probe-hover: not on the main thread at start — refusing to guess where AppKit is")
            exit(1)
        }
        // The arrangement `--probe-ink` needs too: in a shell-launched process the main actor is not
        // the main thread until the application runs, and this probe is about a main-thread callback.
        DispatchQueue.main.async {
            Task { @MainActor in run() }
        }
        NSApplication.shared.run()
        while true { Thread.sleep(forTimeInterval: 3600) }
    }

    private static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        let surface = minimalSurfaceRequested
            ? "a minimal card (text + two buttons)"
            : "the real notch card"
        print("hover probe — can a click over \(surface) still be dispatched?")

        let size = NSSize(width: NotchHUDModel.defaultCardWidth,
                          height: minimalSurfaceRequested ? 200 : 320)
        let host: NSHostingView<AnyView>
        if minimalSurfaceRequested {
            host = NSHostingView(rootView: AnyView(
                VStack {
                    Text("Explaining development session")
                    Button("Allow") {}.buttonStyle(.borderedProminent)
                    Button("Not now") {}.buttonStyle(.bordered)
                }
                .frame(width: size.width, height: size.height)
            ))
        } else {
            // A card with something on it: the empty notch installs fewer responders than an answer
            // does, and the crashes happened under an answer.
            let model = NotchHUDModel()
            let streamer = AnswerStreamer()
            streamer.push("<SAY>The send button is at the bottom right.</SAY>")
            streamer.push("<DONE_TITLE>Where to send</DONE_TITLE>")
            streamer.push("[ACT:955,975:Send]")
            model.apply(streamer)
            model.askConfirm("Press Send?")
            host = NSHostingView(rootView: AnyView(
                NotchHUDView(model: model).frame(width: size.width, height: size.height)
            ))
        }
        host.frame = NSRect(origin: .zero, size: size)
        let window: NSWindow
        if panelSurfaceRequested {
            // The state the card actually lives in: a `.nonactivatingPanel` that is told not to
            // activate the app, in a process whose app is not active because he is working somewhere
            // else. That is the configuration the overlay cost eleven rounds to get right, and it is
            // the one difference between this probe and the minimal window above — a mouse event
            // arriving at a window of an app that never activates.
            let panel = NSPanel(contentRect: host.frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.setValue(true, forKey: "_setPreventsActivation")
            panel.level = .floating
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = host
            window = panel
        } else {
            let plain = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                 backing: .buffered, defer: false)
            plain.contentView = host
            window = plain
        }
        window.setFrameOrigin(NSPoint(x: 200, y: 200))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()

        print("  surface: \(panelSurfaceRequested ? "non-activating panel, app not active" : "plain window")")
        print("  tracking areas in the view tree: \(trackingAreas(in: host))")

        let centre = NSPoint(x: size.width / 2, y: size.height / 2)
        let stamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: centre,
                                            modifierFlags: [], timestamp: stamp,
                                            windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: centre,
                                          modifierFlags: [], timestamp: stamp,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 0) else {
            print("  SKIP: the synthetic click could not be built in this build")
            Log.flush()
            exit(3)
        }

        print("  sending leftMouseDown/up through NSApp at (\(Int(centre.x)), \(Int(centre.y)))…")
        NSApp.sendEvent(down)
        NSApp.sendEvent(up)
        print("  PASS  the click was dispatched and the process is still here — \(surface) is safe")
        Log.write("probe-hover: survived a dispatched click over \(surface)")
        Log.flush()
        exit(0)
    }

    /// Every tracking area in the tree, which is AppKit's own answer to "will this view be handed a
    /// mouse event at all".
    private static func trackingAreas(in view: NSView) -> Int {
        var total = view.trackingAreas.count
        for sub in view.subviews { total += trackingAreas(in: sub) }
        return total
    }
}
