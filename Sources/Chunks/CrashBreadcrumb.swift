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
        // The buffer and the descriptor are made here, while the process is healthy, because the
        // handler that uses them must not allocate or open anything. The path is the log file the
        // user is asked to paste — the same one `Log` writes to.
        if signalTable.isEmpty { buildTables() }
        if logDescriptor < 0 {
            let path = Log.fileURL.path
            path.withCString { pointer in
                logDescriptor = open(pointer, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            }
        }
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

    /// Writes the breadcrumb and re-raises.
    ///
    /// **Nothing in here may allocate, format, dispatch, or touch Objective-C.** The previous version
    /// built the line with string interpolation, opened the log through `URL` and
    /// `ISO8601DateFormatter`, and then called `Log.flush()`, which is `queue.sync {}` — four things
    /// a faulted thread must never try. This app's whole crash class is a bad-pointer dereference
    /// inside Swift Concurrency, and the thread that does that is very often holding the malloc zone
    /// lock: a handler that mallocs does not crash, it **hangs** — the notch frozen, the microphone
    /// and the keyboard tap still held, and the next launch standing down on the single-instance
    /// guard. A diagnostic that can turn a death into a zombie is worse than no diagnostic.
    ///
    /// So every word was `strdup`ed at install, the log's descriptor was opened at install, and the
    /// only calls made here are `strlen` and `write` — the two POSIX guarantees. `snprintf` would have
    /// been the third and Swift does not expose variadic C functions, which is why the sentence is
    /// written in pieces.
    static func report(signalNumber: Int32) {
        guard let strings else { return }
        writeOut(strings.prefix)
        writeOut(lookup(signalTable, signalNumber, strings.unknownSignal))
        writeOut(strings.middle)
        writeOut(lookup(eventTable, lastEventType, strings.noEvent))
        writeOut(strings.onWord)
        writeOut(lookup(surfaceTable, lastEventSurface, strings.noSurface))
        writeOut(strings.uptimeWord)
        writeDigits(UInt64(max(0, Int64(lastEventAt))))
        writeOut(strings.newline)
        signal(signalNumber, SIG_DFL)
        raise(signalNumber)
    }

    /// One NUL-terminated piece, to stderr and to the log. stderr from an app started by `open` is
    /// unreadable — the rule this project already writes probes against — so the bytes have to reach
    /// the file he is asked to paste as well.
    private static func writeOut(_ pointer: UnsafeMutablePointer<CChar>?) {
        guard let pointer else { return }
        let length = strlen(pointer)
        _ = write(STDERR_FILENO, pointer, length)
        if logDescriptor >= 0 { _ = write(logDescriptor, pointer, length) }
    }

    /// The uptime, filled backwards into a buffer allocated at install. There is no formatter here.
    private static func writeDigits(_ value: UInt64) {
        guard let digits = digitBuffer else { return }
        var index = digitBufferSize - 2
        var remaining = value
        repeat {
            digits[index] = CChar(asciiZero + (remaining % 10))
            remaining /= 10
            index -= 1
        } while remaining > 0 && index > 0
        writeOut(digits.advanced(by: index + 1))
    }

    private static let asciiZero: UInt64 = 48
    private static let digitBufferSize = 24
    private static var digitBuffer: UnsafeMutablePointer<CChar>?
    private static var logDescriptor: Int32 = -1
    private static var strings: FaultStrings?

    /// Every word the fault line needs, built once while the process is still healthy.
    private struct FaultStrings {
        let prefix: UnsafeMutablePointer<CChar>
        let middle: UnsafeMutablePointer<CChar>
        let onWord: UnsafeMutablePointer<CChar>
        let uptimeWord: UnsafeMutablePointer<CChar>
        let newline: UnsafeMutablePointer<CChar>
        let unknownSignal: UnsafeMutablePointer<CChar>
        let noEvent: UnsafeMutablePointer<CChar>
        let noSurface: UnsafeMutablePointer<CChar>
    }

    /// Keyed by code, not by name: a `String` built at fault time could be freed or half-written
    /// when the handler runs, and a crash report that prints garbage is no evidence at all.
    private static var signalTable: [(Int32, UnsafeMutablePointer<CChar>)] = []
    private static var eventTable: [(Int32, UnsafeMutablePointer<CChar>)] = []
    private static var surfaceTable: [(Int32, UnsafeMutablePointer<CChar>)] = []

    private static func lookup(_ table: [(Int32, UnsafeMutablePointer<CChar>)],
                               _ code: Int32,
                               _ fallback: UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar> {
        for entry in table where entry.0 == code { return entry.1 }
        return fallback
    }

    private static func buildTables() {
        strings = FaultStrings(
            prefix: strdup("chunks faulted on "),
            middle: strdup(" — last mouse event: "),
            onWord: strdup(" on "),
            uptimeWord: strdup(" at uptime "),
            newline: strdup("\n"),
            unknownSignal: strdup("signal"),
            noEvent: strdup("none-or-other"),
            noSurface: strdup("nothing recorded"))
        digitBuffer = .allocate(capacity: digitBufferSize)
        digitBuffer?[digitBufferSize - 1] = 0
        signalTable = [(SIGSEGV, strdup("SIGSEGV")), (SIGBUS, strdup("SIGBUS")),
                       (SIGILL, strdup("SIGILL")), (SIGABRT, strdup("SIGABRT")),
                       (SIGTRAP, strdup("SIGTRAP"))]
        eventTable = [(Int32(NSEvent.EventType.leftMouseDown.rawValue), strdup("leftMouseDown")),
                      (Int32(NSEvent.EventType.leftMouseUp.rawValue), strdup("leftMouseUp")),
                      (Int32(NSEvent.EventType.rightMouseDown.rawValue), strdup("rightMouseDown")),
                      (Int32(NSEvent.EventType.mouseEntered.rawValue), strdup("mouseEntered")),
                      (Int32(NSEvent.EventType.mouseExited.rawValue), strdup("mouseExited")),
                      (Int32(NSEvent.EventType.mouseMoved.rawValue), strdup("mouseMoved"))]
        surfaceTable = [(surfaceNone, strdup("no window")),
                        (surfaceNotchPanel, strdup("the notch card")),
                        (surfaceMenuBarPanel, strdup("the menu-bar panel")),
                        (surfaceAppWindow, strdup("the app window")),
                        (surfaceDrawingOverlay, strdup("the drawing surface")),
                        (surfaceCaption, strdup("the caption")),
                        (surfaceInk, strdup("the ink layer")),
                        (surfaceOther, strdup("another window"))]
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
