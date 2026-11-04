import AppKit
import ChunksKit
import SwiftUI

/// `Chunks --probe-hover` — can a click over the card be dispatched without the process dying?
///
/// Four crash reports on 2026-11-04 share the same five frames at the top: `swift_getObjectType`
/// ← `swift_task_isMainExecutorImpl` ← `MainActor.assumeIsolated` ← a SwiftUI event binding. The
/// bottom differs, and that difference is the finding: twice `NSHostingView.mouseEntered` →
/// `HoverEventDispatcher`, once `NSHostingView.mouseDown` → `UpdateGroup.dispatchActions` →
/// `_ButtonGesture`. So it is **not** the hover feature — it is SwiftUI's event machinery as such, and
/// deleting `.onHover` would not close it.
///
/// **This probe does not reproduce that fault, and says so.** A synthetic click dispatched through
/// `NSApp.sendEvent` into the real card, the real caption panel and the real ink layer all return
/// normally; a synthetic *enter* delivered straight to the hosting view hangs the process in every
/// combination, including a card made of two plain buttons, which is the probe's own call going where
/// AppKit does not intend rather than the app doing anything. It stays in the gate as a canary for the
/// one thing it can honestly prove — that building and clicking these surfaces is safe in a process
/// that runs them correctly — and the crash itself is left to the breadcrumb, which records what the
/// real app was doing the moment it faults.
///
/// The threading here is load-bearing and was wrong twice: a `Task { @MainActor }` started before
/// `NSApplication.run` is on a pool thread, and AppKit windows built there crash with a message that
/// looks exactly like the bug under investigation. The work therefore begins in
/// `applicationDidFinishLaunching`, which AppKit guarantees on the main thread inside the run loop.
///
/// Nothing is pressed on his machine: the event goes to Chunks' own window inside this process, the
/// pointer does not move, and no other app is touched.
@MainActor
enum HoverProbe {

    static var isRequested: Bool { CommandLine.arguments.contains("--probe-hover") }

    /// The trivial surface, for the fork described above.
    private static var minimalSurfaceRequested: Bool { CommandLine.arguments.contains("--minimal") }

    /// Host the surface in the panel class the real card uses, rather than a plain window.
    private static var panelSurfaceRequested: Bool { CommandLine.arguments.contains("--panel") }

    /// Put the caption panel on screen first. It is the one SwiftUI surface added this week, it is
    /// click-through, and it is up while the voice is speaking — which is exactly when the crashes
    /// happen. If the card alone survives and the card *with* the caption faults, the new surface is
    /// what opened the path.
    private static var captionRequested: Bool { CommandLine.arguments.contains("--with-caption") }

    /// Put a full-screen click-through ink layer over everything before the delivery.
    ///
    /// This is the fork the timeline asks for: the SwiftUI-event crash signature appears for the first
    /// time at 00:53 on 2026-11-04, forty-five minutes after the ink layer shipped, and the ink layer
    /// is the only display-sized surface this app has ever put above his desktop. A click-through
    /// window should not change who receives a hover — that is the claim — and this is the instrument
    /// that tests it instead of arguing about it.
    private static var inkRequested: Bool { CommandLine.arguments.contains("--with-ink") }

    /// Runs the probe from `applicationDidFinishLaunching`, which AppKit guarantees on the main
    /// thread *inside* the run loop.
    ///
    /// The first three versions of this probe enqueued `Task { @MainActor in run() }` and then started
    /// the application. That race is the whole lesson of the 00:53 crash report and of the ink probe's
    /// "NSWindow should only be instantiated on the main thread": in a shell-launched process the main
    /// actor is a pool thread until `NSApplication` runs, so the task body — and every AppKit call in
    /// it — could run on the wrong thread. A probe that measures the main thread must not itself be
    /// off it, or its answer describes the probe. Anything this file reports is only evidence because
    /// the work now starts from the delegate callback.
    private static let delegateHolder = HoverProbeDelegate()

    static func start() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        guard Thread.isMainThread else {
            print("probe-hover: not on the main thread at start — refusing to guess where AppKit is")
            exit(1)
        }
        let app = NSApplication.shared
        app.delegate = delegateHolder
        app.setActivationPolicy(.accessory)
        app.run()
        // Unreachable: the delegate exits the process.
        while true { Thread.sleep(forTimeInterval: 3600) }
    }

    /// The only job is to be the thing AppKit calls on the main thread once the loop is turning.
    private final class HoverProbeDelegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            MainActor.assumeIsolated { run() }
        }
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
        // Parked below every display before it is ever ordered front. The window is still laid out,
        // still hit-testable and still receives the events dispatched to its window number — the
        // probe answers the same question — but it is never composited onto the desktop he is working
        // on, which is the property a gate must not cost him.
        guard ProbeWindow.parkOffscreen(window, size: size) else {
            print("SKIP: the probe could not place its card off every display, so it will not show one")
            Log.flush()
            exit(3)
        }
        ProbeWindow.reportParked(window)
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()

        print("  surface: \(panelSurfaceRequested ? "non-activating panel, app not active" : "plain window")")
        print("  tracking areas in the view tree: \(trackingAreas(in: host))")

        let captions: CaptionPanelManager?
        if captionRequested {
            // The real manager, the real panel, the real sentence — click-through and never key, up
            // while the voice speaks.
            let shown = CaptionPanelManager()
            shown.show("The send button is at the bottom right of the chat.")
            captions = shown
            print("  caption panel up: \(shown.isShowing) — now delivering the hover")
        } else {
            captions = nil
        }

        let ink: InkLayerManager?
        if inkRequested, let display = CaptureEngine.mainDisplay() {
            // A real mark on the real display, the same surface a circled turn leaves up.
            let layer = InkLayerManager()
            let local = display.space.localRect(fromGlobal: display.frame)
            layer.show([.rect(LogicalRect(x: local.minX + 200, y: local.minY + 200,
                                          width: 300, height: 200))],
                       on: display, limitSeconds: 30)
            ink = layer
            print("  ink layer up over the display: \(layer.isShowing)")
        } else {
            ink = nil
        }

        // A tracking-area *enter* is what the crash reports pass through, but delivering one by hand
        // does not reproduce them: `host.mouseEntered(with:)` with a synthetic event HANGS the process
        // every time, in every surface combination, including a card with two plain buttons in it. A
        // probe that hangs is not evidence about the app — it is the probe's own call going somewhere
        // AppKit never intends. So this canary dispatches only what it can dispatch honestly, a click
        // through the application, and says plainly that it does NOT reproduce the fault.
        let stamp = ProcessInfo.processInfo.systemUptime

        let centre = NSPoint(x: size.width / 2, y: size.height / 2)
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
        captions?.hide()
        ink?.clear(reason: "the probe finished")

        // The shield, asserted against a laid-out card. The two floating surfaces host their SwiftUI
        // in a view that strips enter/exit tracking areas the moment SwiftUI installs them, because
        // `mouseEntered` is the message whose dispatch has faulted three times and been named twice by
        // the breadcrumb. Zero areas is the proof: with none, AppKit has nothing to fire and
        // HoverEventDispatcher is never entered. (No synthetic enter event is delivered here on
        // purpose — on an unshielded host that call hangs the process, which is the probe's own call
        // going somewhere AppKit never intends, not evidence about the app.)
        let shieldModel = NotchHUDModel()
        let shieldStream = AnswerStreamer()
        shieldStream.push("<SAY>The send button is at the bottom right.</SAY>")
        shieldStream.push("[ACT:955,975:Send]")
        shieldModel.apply(shieldStream)
        shieldModel.askConfirm("Press Send?")
        let shield = HoverShieldHostingView(rootView: AnyView(
            NotchHUDView(model: shieldModel).frame(width: size.width, height: size.height)))
        shield.frame = NSRect(origin: .zero, size: size)
        let shieldWindow = NSWindow(contentRect: shield.frame, styleMask: [.borderless],
                                    backing: .buffered, defer: false)
        shieldWindow.contentView = shield
        guard ProbeWindow.parkOffscreen(shieldWindow, size: size) else {
            print("SKIP: the shield's card could not be parked off every display")
            Log.flush()
            exit(3)
        }
        shieldWindow.orderFrontRegardless()
        shield.layoutSubtreeIfNeeded()
        let hoverAreas = enterExitAreas(in: shield)
        print("  shield: \(hoverAreas) enter/exit tracking area(s) on a laid-out card")
        if hoverAreas != 0 {
            print("  FAIL  the hover shield let SwiftUI keep \(hoverAreas) enter/exit area(s)")
            Log.flush()
            exit(1)
        }

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

    /// The subset that delivers `mouseEntered` — the only subset the shield may not keep.
    private static func enterExitAreas(in view: NSView) -> Int {
        var total = view.trackingAreas.filter { $0.options.contains(.mouseEnteredAndExited) }.count
        for sub in view.subviews { total += enterExitAreas(in: sub) }
        return total
    }
}
