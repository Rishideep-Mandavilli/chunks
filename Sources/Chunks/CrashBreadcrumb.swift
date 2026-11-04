import AppKit
import Foundation

/// The last thing the app was asked to do, written out when the process is about to die.
///
/// Four crash reports today all fault inside SwiftUI's event dispatch — `MainActor.assumeIsolated`
/// reading the runtime's main-executor answer and segfaulting on it — and none of them says *which
/// surface* or *which event*. The log stops mid-sentence because a SIGSEGV does not flush, so the
/// evidence that would separate "the first click after a streamed answer" from "a hover over the
/// confirm row" is exactly the evidence that is lost.
///
/// Two small pieces fix that. A passive local event monitor records the last mouse event AppKit handed
/// this app — it records and returns the event, touching nothing else, because the rule this file
/// exists to serve is that a callback must not assert the main actor. And a signal handler writes one
/// line with `write(2)` — the only call that is safe on a thread that has just faulted — before
/// re-raising the default so macOS still writes its report and the exit code still says 139.
///
/// This is not a fix for the crash. It is the instrument that turns the next one into a sentence.
enum CrashBreadcrumb {

    /// Recorded from the event monitor's own thread, which is the main thread; read from a signal
    /// handler, which can fire on any thread. Every field is one machine word and nothing here is
    /// allowed to allocate, because the handler runs on a thread that has just faulted.
    private static var lastEventType: Int32 = 0
    private static var lastEventSurface: Int32 = surfaceUnknown
    private static var lastEventAt: Double = 0
    private static var installed = false

    /// The window classes, named by code rather than by a string: a `String` built at record time
    /// could be freed or half-written when the handler runs, and a crash report that prints garbage is
    /// no evidence at all.
    private static let surfaceNone = Int32(0)
    private static let surfaceNotchPanel = Int32(1)
    private static let surfaceMenuBarPanel = Int32(2)
    private static let surfaceAppWindow = Int32(3)
    private static let surfaceDrawingOverlay = Int32(4)
    private static let surfaceCaption = Int32(5)
    private static let surfaceInk = Int32(8)
    private static let surfaceOther = Int32(6)
    private static let surfaceUnknown = Int32(7)

    static func install() {
        guard !installed else { return }
        installed = true
        // SIGTRAP is in the set because a Swift runtime trap raises it rather than a signal of the
        // memory kind, and the first run of `--probe-crash` died with a Swift `Fatal error:` and no
        // breadcrumb at all — the handler was listening for the wrong four.
        for signalNumber in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP] {
            signal(signalNumber, crashBreadcrumbHandler)
        }
        // Mouse events only, and only recorded. `.mouseEntered` and `.mouseExited` are in the set
        // because two of the four crashes arrived through a tracking-area enter, and the third through
        // a mouse-down — the difference between them is the thing worth knowing next time.
        NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown,
                       .mouseEntered, .mouseExited, .mouseMoved]
        ) { event in
            note(event)
            return event
        }
        writeLine("breadcrumb: installed — the last mouse event will be named if this process faults")
        // And in the log, where it can actually be read after a GUI launch: without this line there is
        // no way to tell "the handler is armed" from "this build predates the handler".
        Log.write("breadcrumb: armed — a fault will name the last mouse event and its surface")
    }

    private static func note(_ event: NSEvent) {
        lastEventType = Int32(truncatingIfNeeded: event.type.rawValue)
        lastEventAt = event.timestamp
        guard let window = event.window else {
            lastEventSurface = surfaceNone
            return
        }
        // Matched on the window's own identifier rather than on its class, because the notch card and
        // the menu-bar panel are the *same* private class — `KeyablePanel` — and the first version of
        // this reported "another window" for a fault that happened on the card.
        switch window.identifier?.rawValue {
        case "notch-card": lastEventSurface = surfaceNotchPanel
        case "menu-bar-panel": lastEventSurface = surfaceMenuBarPanel
        default:
            let className = NSStringFromClass(type(of: window))
            if className.contains("AnnotationPanel") || className.contains("OverlayWindow") {
                lastEventSurface = surfaceDrawingOverlay
            } else if className.contains("InkPanel") {
                lastEventSurface = surfaceInk
            } else if className.contains("CaptionPanel") {
                lastEventSurface = surfaceCaption
            } else if className.contains("Window") && !className.contains("Panel") {
                lastEventSurface = surfaceAppWindow
            } else {
                lastEventSurface = surfaceOther
            }
        }
    }

    /// Writes the breadcrumb and re-raises. Only async-signal-safe calls: `write(2)` and `raise`.
    static func report(signalNumber: Int32) {
        let name: StaticString
        switch signalNumber {
        case SIGSEGV: name = "SIGSEGV"
        case SIGBUS: name = "SIGBUS"
        case SIGILL: name = "SIGILL"
        case SIGABRT: name = "SIGABRT"
        default: name = "signal"
        }
        let event = eventName(lastEventType)
        let surface = surfaceName(lastEventSurface)
        let seconds = Int32(lastEventAt)
        let line = "chunks faulted on \(name) — last mouse event: \(event) on \(surface) "
            + "at uptime \(seconds)s"
        line.withCString { pointer in
            _ = write(STDERR_FILENO, pointer, strlen(pointer))
        }
        // stderr from an app started by `open` is unreadable — the rule this project already writes
        // probes against — so the sentence has to reach the log file he pastes from, synchronously.
        Log.appendEmergency(line)
        // The buffered log lines of the last seconds are the other half of the story, and a fault
        // never gets to flush them normally.
        Log.flush()
        signal(signalNumber, SIG_DFL)
        raise(signalNumber)
    }

    private static func surfaceName(_ code: Int32) -> StaticString {
        switch code {
        case surfaceNone: return "no window"
        case surfaceNotchPanel: return "the notch card"
        case surfaceMenuBarPanel: return "the menu-bar panel"
        case surfaceAppWindow: return "the app window"
        case surfaceDrawingOverlay: return "the drawing surface"
        case surfaceCaption: return "the caption"
        case surfaceInk: return "the ink layer"
        case surfaceOther: return "another window"
        default: return "nothing recorded"
        }
    }

    private static func eventName(_ raw: Int32) -> StaticString {
        switch Int(raw) {
        case Int(NSEvent.EventType.leftMouseDown.rawValue): return "leftMouseDown"
        case Int(NSEvent.EventType.leftMouseUp.rawValue): return "leftMouseUp"
        case Int(NSEvent.EventType.rightMouseDown.rawValue): return "rightMouseDown"
        case Int(NSEvent.EventType.mouseEntered.rawValue): return "mouseEntered"
        case Int(NSEvent.EventType.mouseExited.rawValue): return "mouseExited"
        case Int(NSEvent.EventType.mouseMoved.rawValue): return "mouseMoved"
        default: return "none-or-other"
        }
    }

    private static func writeLine(_ text: String) {
        text.withCString { pointer in
            _ = write(STDERR_FILENO, pointer, strlen(pointer))
        }
    }
}

/// The signal handler itself, at file scope because `signal(2)` takes a C function pointer and a
/// closure that closes over anything at all cannot become one.
private func crashBreadcrumbHandler(_ number: Int32) {
    CrashBreadcrumb.report(signalNumber: number)
}

/// `Chunks --probe-crash` — does a fault leave a sentence behind?
///
/// The breadcrumb is only worth having if it survives the thing it exists for: a handler that runs on
/// a faulted thread, prints nothing, and dies silently is the current behaviour, which is why four
/// reports today answered no questions. So this probe does the worst thing on purpose — records a real
/// mouse event, then reads address `0x1` — and the assertion is what comes out of the wreckage.
///
/// The process is *expected* to die with signal 11. The check is that it says so first, in words, and
/// that the buffered log reaches the file.
@MainActor
enum CrashProbe {

    static var isRequested: Bool { CommandLine.arguments.contains("--probe-crash") }

    static func start() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        print("crash probe — this process is meant to die, and to say what it was doing")
        CrashBreadcrumb.install()

        let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 200, height: 120),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        // Off every display, like every other probe window: this one runs in the gate, and a helper
        // window appearing on his desktop is not a diagnostic, it is a false alarm.
        if ProbeWindow.parkOffscreen(window, size: NSSize(width: 200, height: 120)) {
            window.orderFrontRegardless()
        }

        let stamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown,
                                            location: NSPoint(x: 150, y: 160),
                                            modifierFlags: [], timestamp: stamp,
                                            windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1) else {
            print("SKIP: no synthetic event could be built")
            exit(3)
        }
        // Delivered through the application, so the local monitor sees it the way a real click does.
        NSApp.sendEvent(down)
        Log.write("crash-probe: about to fault on purpose")
        Log.flush()
        print("  a leftMouseDown was recorded; faulting now…")

        // The fault itself: a read of an aligned address that is not mapped, which is what the
        // SwiftUI path does when its executor check dereferences a job that is no longer there.
        // Misaligned first, this became a Swift `Fatal error:` and a SIGTRAP instead of the
        // SIGSEGV the real crash raises — the address is page-aligned on purpose.
        let wild = UnsafeRawPointer(bitPattern: 0x0000_1000_0000_0000)!
        print("  (this line never prints: \(wild.load(as: Int.self)))")
        exit(0)
    }
}
