//
//  AnnotationOverlay.swift
//  Chunks
//
//  Imported from the vendored farzaa/clicky source (MIT) — this is `AnnotationOverlayWindow`
//  and `AnnotationCanvas` as they existed in `Sources/Chunks/AppShell.swift` before commit
//  `10bd07e` deleted that file. Recovered with `git show 10bd07e^:Sources/Chunks/AppShell.swift`.
//
//  It is imported rather than rewritten because the rewrite is what locked the user's Mac on
//  2026-10-11. Upstream gets the dangerous part right and my version got it wrong: this is a
//  `.nonactivatingPanel`, so the app the user was using is never *activated* — no `NSApp.activate`
//  anywhere in this file. Mine demanded activation, took `NSApp.activate(ignoringOtherApps:)`, and
//  made Escape and Return the only exits — so when focus did not arrive there was no way out of a
//  display-sized, click-swallowing window sitting above the menu bar.
//
//  Chunks' version does let this panel become *key*, which upstream's did not, because a borderless
//  `NSPanel` that cannot become key never receives `keyDown` and so silently disables every
//  keyboard exit in the file (measured 2026-10-12: `key=false` for a whole session). Key is not
//  active: the user's app stays frontmost and the menu bar stays theirs, while this window gets the
//  pen and the Return that asks the question. The three exits below need neither of those.
//
//  Three exits are added below, none of which upstream had, because "the user can always press
//  Escape" is a promise this codebase has now seen broken:
//      · right-click anywhere cancels — needs no keyboard and no focus;
//      · no activity for `idleLimitSeconds` cancels — a forgotten overlay cannot outlive itself;
//      · an absolute cap cancels regardless of activity, so a drawing hand cannot strand it.
//

import AppKit
import ChunksKit

/// The full-screen drawing surface, shown for one question.
@MainActor
final class AnnotationOverlayWindow: NSObject, NSWindowDelegate {

    /// A drawing session with no input is a mistake or an abandoned attempt; it is not a reason to
    /// keep a click-swallowing window on screen.
    nonisolated static let idleLimitSeconds: TimeInterval = 30
    /// Even a actively-drawing user should not be under this window forever.
    nonisolated static let absoluteLimitSeconds: TimeInterval = 120

    private let display: DisplayInfo
    /// Shapes plus the words spoken over them, which may be empty.
    private let onSubmit: ([AnnotationShape], String) -> Void
    private let idleLimitSeconds: TimeInterval
    private let absoluteLimitSeconds: TimeInterval
    private var window: NSPanel?
    private let canvas = AnnotationCanvas()
    /// Called once when the surface goes away for any reason. Without it the owner cannot tell
    /// "dismissed" from "still covering the screen", and the chord would have no way to know it is
    /// supposed to be a toggle.
    var onDismissed: (() -> Void)?

    private var idleTimer: Timer?
    private var absoluteTimer: Timer?
    private var isClosed = false
    /// A local event monitor, kept so it can be removed with the window. See `startClickWatch()`.
    private var clickWatch: Any?
    /// The global counterpart: sees clicks that go to somebody else's window.
    private var outsideWatch: Any?
    /// App-wide Escape, so the keyboard exit survives a window that never became key.
    private var escapeWatch: Any?
    private var clicksWatched = 0

    init(display: DisplayInfo,
         onSubmit: @escaping ([AnnotationShape], String) -> Void,
         idleLimitSeconds: TimeInterval = AnnotationOverlayWindow.idleLimitSeconds,
         absoluteLimitSeconds: TimeInterval = AnnotationOverlayWindow.absoluteLimitSeconds) {
        self.display = display
        self.onSubmit = onSubmit
        self.idleLimitSeconds = idleLimitSeconds
        self.absoluteLimitSeconds = absoluteLimitSeconds
        super.init()
    }

    /// Show the surface. Returns false when it refused, so the caller can fall back to a gesture
    /// that does not depend on this window taking the mouse.
    @discardableResult
    func show() -> Bool {
        guard let frame = appKitFrame() else {
            // No overlay at all beats an overlay on the wrong display: the drawing would be
            // visible on one screen and the crop would come from another.
            Log.write("annotate: refused — display \(display.displayID) matches no NSScreen "
                + "(screens=\(NSScreen.screens.count))")
            return false
        }

        let panel = AnnotationPanel(contentRect: frame,
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered,
                                    defer: false)
        // Imported configuration, not invented: this is Capso's `CaptureOverlayWindow` (MIT), a
        // shipping `LSUIElement` tool whose display-sized overlay takes the mouse at
        // `.screenSaver` level. Where it differs from what this file had — `.transient` rather than
        // `.stationary`, `ignoresMouseEvents` stated instead of defaulted, `isMovable = false`, and
        // the activation rule below — those are questions its author already settled.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = canvas

        // The load-bearing line. AppKit treats a mouse-down in a window of an *inactive* app as an
        // attempt to activate that app and swallows the click — which is exactly the symptom here:
        // the panel was key, was frontmost over the point, received `keyDown`, and received no
        // mouse event at all, measured three times on the user's Mac. `_setPreventsActivation:`
        // says this window may take clicks without the app becoming active, so his frontmost app
        // keeps the menu bar and the pen still works. It is private and unversioned, hence the
        // guard: if it ever disappears, this surface loses the pen and nothing else changes.
        let preventsActivation = NSSelectorFromString("_setPreventsActivation:")
        let guarded = panel.responds(to: preventsActivation)
        if guarded {
            panel.perform(preventsActivation, with: NSNumber(value: true))
        }

        // Content-local, not the display's global frame: a view's origin inside its own window is
        // (0,0), and `localPoint` converts window coordinates into this view. Copying the global
        // frame here was harmless while the overlay was only ever on the display at (0,0) and would
        // put every mark off-screen on a second display parked at x = 1710.
        canvas.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
        canvas.dimsScreen = true
        canvas.onSubmit = { [weak self] shapes in self?.submit(shapes) }
        canvas.onCancel = { [weak self] reason in self?.cancel(reason: reason) }
        canvas.onActivity = { [weak self] in self?.restartIdleTimer() }

        window = panel
        isClosed = false
        // Order first, then take key status — Capso's order, and not the same thing as
        // `makeKeyAndOrderFront`: on a `.nonactivatingPanel` the split pair makes the window key for
        // Escape and Return without touching which app is active.
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(canvas)
        installEscapeFallback()
        restartIdleTimer()
        absoluteTimer = Timer.scheduledTimer(withTimeInterval: absoluteLimitSeconds, repeats: false) {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.cancel(reason: "reached its time limit") }
        }
        Log.write("annotate: overlay open on \(Int(frame.width))x\(Int(frame.height))pt display, "
            + "auto-dismissing after \(Int(idleLimitSeconds))s idle / \(Int(absoluteLimitSeconds))s total, "
            + "activation guard=\(guarded)")
        startClickWatch()
        // Not in this runloop turn: the window server has not registered a window in the same turn
        // that created it, so a list read here reports "not on screen" about a window that is about
        // to be. That is exactly what the first version of this probe did, and its answer —
        // `the overlay takes clicks: false` — was untrustworthy. The cursor overlay waits 1.5 s for
        // the same reason.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.isClosed, let panel = self.window else { return }
            self.logClickPath(panel: panel)
        }
        return true
    }

    /// Escape, caught app-wide rather than only through the responder chain.
    ///
    /// Copied from the same upstream design: if the activation guard above ever stops working, the
    /// window may not be key, and then the canvas's `keyDown` never fires — which would leave the
    /// keyboard exits dead while looking correct in the code. This keeps at least one door open on
    /// the assumption that the window is key. The other exits — right-click, the idle and absolute
    /// timers, and the chord — never depended on it.
    private func installEscapeFallback() {
        escapeWatch = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in self?.cancel(reason: "escape (app-wide)") }
        }
    }

    /// This display's rect in AppKit's bottom-left space, which is what `NSPanel(contentRect:)`
    /// wants.
    ///
    /// `DisplayInfo.frame` is `CGDisplayBounds` — top-left origin. The two differ by the *origin*,
    /// never the size, so on the display parked at (0,0) mixing them is invisible and on any other
    /// it puts the overlay on the wrong screen. Invariant 1's rule, applied to this window; the
    /// lookup itself is `DisplayScreens`, shared with the ink layer so the two surfaces cannot
    /// disagree about which screen a display is.
    private func appKitFrame() -> NSRect? {
        DisplayScreens.matching(display)?.frame
    }

    /// Where a click would land, according to AppKit, and which on-screen windows cover that
    /// point — front to back.
    ///
    /// Written because the user pressed the chord, watched the overlay appear, drew on it and the
    /// log recorded *no* `mouse down` at all (2026-10-12, 30 s session ended in the idle timeout).
    /// That leaves two candidates with opposite fixes — the panel is not in the window server's hit
    /// path, or the event reaches the app and is routed to another window — and the previous guess
    /// at this (`acceptsFirstMouse`) cost a rebuild and a test for nothing. This states which one
    /// it is from the window list and a hit test, not from reasoning about style masks.
    private func logClickPath(panel: NSPanel) {
        let frame = panel.frame
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        // Stated first because it changes how every line below is read: while the display is asleep
        // or locked, the window server's own windows sit above level 1000 and nothing this app draws
        // is on the on-screen list. A probe run at 22:05 on 2026-10-12 reported `takes clicks: false`
        // against `loginwindow#2004` for exactly that reason, and the answer had nothing to do with
        // the overlay.
        Log.write("annotate: display \(display.displayID) asleep=\(CGDisplayIsAsleep(display.displayID) != 0) "
            + "active=\(CGDisplayIsActive(display.displayID) != 0) screens=\(NSScreen.screens.count)")
        // Chunks' own windows covering the point, level first. The buddy cursor overlay is a
        // full-screen `.screenSaver` window too, and whether it is above or below the annotation
        // panel decides who gets the drag — so it is named here rather than assumed absent.
        let ours = NSApp.windows.filter { $0.isVisible && $0.frame.contains(centre) }
            .map { "\($0.className) level=\($0.level.rawValue) mouseThrough=\($0.ignoresMouseEvents) #\($0.windowNumber)" }
        Log.write("annotate: this app's windows over that point: \(ours.joined(separator: " | ")) "
            + "(overlay is #\(panel.windowNumber), key=\(panel.isKeyWindow))")

        // Front-to-back, exactly as the window server would deliver a click. `NSWindow.windowNumber`
        // *is* the CGWindowID, so the overlay can be located by identity rather than by assuming it
        // is first — the first one that covers the point is the one that gets the mouse.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                             kCGNullWindowID) as? [[String: Any]] ?? []
        var covering: [(id: Int, owner: String, layer: Int)] = []
        for entry in list {
            guard let boundsObject = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsObject),
                  bounds.contains(centre) else { continue }
            covering.append((entry[kCGWindowNumber as String] as? Int ?? -1,
                             entry[kCGWindowOwnerName as String] as? String ?? "?",
                             entry[kCGWindowLayer as String] as? Int ?? -1))
        }
        let summary = covering.prefix(6).map { "\($0.owner)#\($0.layer)/\($0.id)" }
            .joined(separator: " → ")
        let frontmost = covering.first
        Log.write("annotate: \(covering.count) windows over that point, first six front→back: \(summary)")
        Log.write("annotate: frontmost over that point is "
            + "\(frontmost?.owner ?? "nothing")#\(frontmost?.layer ?? -1)/\(frontmost?.id ?? -1) "
            + "— the overlay takes clicks: \(frontmost?.id == panel.windowNumber)")
    }

    /// Watches mouse events destined for *this app's* windows while the overlay is up, and says
    /// whether the click reached the canvas — the distinction the log could not make before.
    ///
    /// A global monitor runs alongside it, and the pair is what makes the answer readable: a click
    /// seen by the global monitor and not the local one went to *another app's* window, while a
    /// click seen by neither was never delivered by the window server at all. Those two look the
    /// same from the canvas — nothing arrives — and need opposite fixes.
    private func startClickWatch() {
        clicksWatched = 0
        clickWatch = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, self.clicksWatched < 6 else { return event }
            self.clicksWatched += 1
            Log.write("annotate: click watch — \(Self.name(of: event)) → window "
                + "#\(event.window?.windowNumber ?? -1) inCanvas=\(event.window?.contentView === self.canvas)")
            return event
        }
        outsideWatch = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, self.clicksWatched < 6 else { return }
            self.clicksWatched += 1
            Log.write("annotate: click watch — \(Self.name(of: event)) went OUTSIDE Chunks "
                + "at (\(Int(event.locationInWindow.x)), \(Int(event.locationInWindow.y)))")
        }
    }

    private static func name(of event: NSEvent) -> String {
        switch event.type {
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseDragged: return "leftMouseDragged"
        case .leftMouseUp: return "leftMouseUp"
        case .rightMouseDown: return "rightMouseDown"
        case .keyDown: return "keyDown keyCode=\(event.keyCode)"
        default: return "\(event.type.rawValue)"
        }
    }

    /// The words the user spoke over the surface, read out of the dictation in flight.
    ///
    /// Called *before* the surface closes, because closing fires `onDismissed`, and the owner
    /// discards an uncommitted dictation there — reading the transcript afterwards finds nothing,
    /// and the user's actual question would be replaced by the default one.
    var transcriptProvider: (() -> String)?

    private func submit(_ shapes: [AnnotationShape]) {
        guard !shapes.isEmpty else {
            // Same lesson `CropMarkupWindow` learned on its first real run: an empty Return is the
            // user confirming the gesture, not abandoning it, and closing without a word reads as
            // Chunks ignoring him.
            Log.write("annotate: Return with nothing drawn — the surface stays open")
            canvas.setHint("Draw or speak · Return to ask · Esc or right-click to cancel")
            return
        }
        let spoken = transcriptProvider?() ?? ""
        let closeHappened = close()
        guard closeHappened else { return }
        onSubmit(shapes, spoken)
    }

    /// Restart the countdown on any input, so a person actually drawing is never cut off mid-mark.
    private func restartIdleTimer() {
        guard !isClosed else { return }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleLimitSeconds, repeats: false) {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.cancel(reason: "no input for \(Int(self?.idleLimitSeconds ?? 0))s") }
        }
    }

    @discardableResult
    private func cancel(reason: String) -> Bool {
        guard close() else { return false }
        Log.write("annotate: dismissed — \(reason)")
        return true
    }

    /// False when it was already gone, so a double dismissal cannot fire two callbacks and a
    /// second question.
    @discardableResult
    private func close() -> Bool {
        guard !isClosed else { return false }
        isClosed = true
        idleTimer?.invalidate()
        idleTimer = nil
        absoluteTimer?.invalidate()
        absoluteTimer = nil
        if let watch = clickWatch { NSEvent.removeMonitor(watch); clickWatch = nil }
        if let watch = outsideWatch { NSEvent.removeMonitor(watch); outsideWatch = nil }
        if let watch = escapeWatch { NSEvent.removeMonitor(watch); escapeWatch = nil }
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        onDismissed?()
        return true
    }

    /// The chord pressed again. An exit that needs neither the keyboard focus of this window nor
    /// a click inside it, which is the whole lesson of the 2026-10-11 lockup.
    func dismissByChord() { cancel(reason: "chord pressed again") }

    func windowWillClose(_ notification: Notification) { cancel(reason: "window closed") }
}

/// A borderless panel that can become key without activating Chunks.
///
/// Shared by the two annotate surfaces (the parked full-screen one and `CropMarkupWindow`) because
/// a plain borderless `NSPanel` cannot become key, which silently deletes every keyboard exit:
/// `keyDown` is never delivered, so Escape, Return and Space become unreachable code while the code
/// to handle them sits in the file. `MenuBarPanelManager` and `NotchPanelManager` each hold their
/// own private copy of these three lines, and those two surfaces take the user's clicks today.
final class AnnotationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Never main: a display-sized window that became main would take the user's app out of the
    /// menu bar while he draws. Key is enough for Escape and Return.
    override var canBecomeMain: Bool { false }
}

/// The drawing surface: freehand, ellipse, rect, arrow, plus undo and submit.
final class AnnotationCanvas: NSView {

    var onSubmit: (([AnnotationShape]) -> Void)?
    /// Reason kept so the log can say *which* exit the user used — the difference between
    /// "pressed Escape" and "timed out" is a design signal, not noise.
    var onCancel: ((String) -> Void)?
    var onActivity: (() -> Void)?

    private var session = AnnotationSession()
    private var activePoints: [LogicalPoint] = []
    private var dragStart: LogicalPoint?
    private var tool: Tool = .pen

    /// Distance of the hint strip from the top edge. `nil` means "clear of the physical notch",
    /// which is only the right question for a surface covering the whole display.
    var hintTopInset: CGFloat?

    /// The line the user reads while drawing, when the default is not the truth for this surface.
    var hintText: String?

    /// Shade the live desktop behind the marks.
    ///
    /// Without it, "draw mode" is invisible: the surface is transparent, so the only sign the
    /// screen is being held for a circle is a line of text the user has to look for. A light dim
    /// says it in one glance and makes a red mark legible on any wallpaper. It is off for a canvas
    /// that already shows a frozen crop — dimming the thing being annotated would only hurt.
    /// Nothing of this reaches the screenshot: the capture is taken after the surface closes.
    var dimsScreen = false

    /// Light enough to read a button label through, dark enough to see against a white page.
    static let screenTint = NSColor.black.withAlphaComponent(0.18)

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
        /// One click, one point. The mark that says "this exact thing" rather than "this area".
        case pin = "Pin"
        /// Rub at a mark and it goes. Topmost first, because that is the one he can see on top.
        case eraser = "Eraser"

        var symbol: String {
            switch self {
            case .pen: return "scribble.variable"
            case .ellipse: return "circle"
            case .rect: return "rectangle"
            case .arrow: return "arrow.up.right"
            case .pin: return "mappin.circle.fill"
            case .eraser: return "eraser"
            }
        }

        /// Whether a drag draws this tool, or a single click finishes it.
        ///
        /// A pin and an eraser are click tools: dragging a pin would be a stroke he did not ask for,
        /// and an eraser that only worked on click would make rubbing out a pile of ink a chore of
        /// single taps. The eraser is the exception that also acts while dragged.
        var isClickOnly: Bool { self == .pin }
    }

    private enum DragPhase { case drawing, choosingTool }

    private var dragPhase: DragPhase = .drawing

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    /// The panel is deliberately never key, so AppKit would otherwise treat a click in it as an
    /// attempt to activate it and *discard the drag*: `mouseDown` never arrives, the pen draws
    /// nothing, and the user watches a full-screen layer refuse to take a mark. Checked
    /// 2026-10-12 — the chord opened the overlay and the hint rendered, and every draw was empty.
    /// Accepting first mouse takes the stroke without taking focus from the app behind it, which
    /// is the property the 2026-10-11 lockup made non-negotiable.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    private func localPoint(_ event: NSEvent) -> LogicalPoint {
        // The view is flipped, so `convert` gives top-left-origin coordinates that match
        // `LogicalPoint`'s convention directly. No y-flipping anywhere else.
        let p = convert(event.locationInWindow, from: nil)
        return LogicalPoint(x: Double(p.x), y: Double(p.y))
    }

    override func mouseDown(with event: NSEvent) {
        onActivity?()
        let point = localPoint(event)
        Log.write("annotate: mouse down — tool=\(tool.rawValue) at "
            + "(\(Int(point.x)), \(Int(point.y)))")
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

    /// Right-click is the exit that does not depend on the keyboard or on focus, which is the
    /// whole lesson of the 2026-10-11 lockup: an overlay whose only door is a key press is a
    /// door that can disappear.
    override func otherMouseDown(with event: NSEvent) {
        onCancel?("right-click")
    }

    override func mouseDragged(with event: NSEvent) {
        onActivity?()
        let point = localPoint(event)
        switch tool {
        case .pen:
            activePoints.append(point)
        case .ellipse, .rect, .arrow:
            break  // Derived from dragStart to the current point at draw time.
        case .pin:
            break  // A pin is placed on release; dragging one would be a stroke he did not ask for.
        case .eraser:
            // Rubbing is a drag, so the eraser acts on every move, not only on release. A click-only
            // eraser would make clearing a pile of ink a chore of single taps.
            if session.erase(at: point) {
                Log.write("annotate: erased a mark — \(session.shapes.count) left")
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onActivity?()
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
        case .pin:
            // Placed where he let go, not where he pressed: a pin dragged across the screen while he
            // was aiming is still a pin at the place he stopped, which is the place he meant.
            shape = .pin(point)
        case .eraser:
            // The release is the last chance to catch a tap that never dragged.
            if session.erase(at: point) {
                Log.write("annotate: erased a mark — \(session.shapes.count) left")
            }
            shape = nil
        }

        if let shape {
            session.add(shape)
            Log.write("annotate: mark added — \(session.shapes.count) total")
        } else {
            // Distinguishing "the drag was too short to be a mark" from "the drag never arrived"
            // is the difference between a threshold bug and a dead event path.
            Log.write("annotate: drag made no mark")
        }
        activePoints = []
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // `bounds`, not `dirtyRect`: a mark being dragged dirties only its own rectangle, and a
        // partial fill would leave the rest of the screen unshaded.
        (dimsScreen ? Self.screenTint : NSColor.clear).setFill()
        bounds.fill()

        // The in-progress shape is drawn last so a mark being dragged is always on top.
        var drawable = session.shapes
        if let pending = inProgressShape() { drawable.append(pending) }

        for shape in drawable {
            Self.draw(shape)
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
        case .pin:
            // Shown under the cursor while he is deciding where to put it, so a pin is never a
            // surprise on release.
            return .pin(end)
        case .eraser:
            // Nothing in progress: the eraser changes the session directly as it moves.
            return nil
        }
    }

    /// One mark, drawn.
    ///
    /// The single entry point for every surface that shows his ink — this canvas, the crop markup and
    /// the layer that keeps the marks on screen while the turn runs — because three copies of "how a
    /// mark looks" is three chances for what he sees and what the model is shown to drift apart. The
    /// pin is the case that proves the point: it is *filled*, and a stroked ring here against a solid
    /// disc in the burn-in would make "the thing I pinned" two different marks in two pictures.
    static func draw(_ shape: AnnotationShape) {
        let ink = NSColor(cgColor: AnnotationShape.overlayStrokeColor)
        switch shape {
        case .pin(let point):
            let dot = AnnotationShape.pinDotRadius
            ink?.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - dot, y: point.y - dot,
                                        width: dot * 2, height: dot * 2)).fill()
            // A pale ring, the same one the burn-in paints: a solid red dot on a dark wallpaper is
            // legible, and on a red one it is not.
            let ring = AnnotationShape.pinDotRadius + AnnotationShape.pinRingGap
            let halo = NSBezierPath(ovalIn: NSRect(x: point.x - ring, y: point.y - ring,
                                                   width: ring * 2, height: ring * 2))
            halo.lineWidth = AnnotationShape.pinRingWidth
            NSColor.white.setStroke()
            halo.stroke()

        default:
            guard let path = path(for: shape) else { return }
            path.lineWidth = AnnotationShape.strokeWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            ink?.setStroke()
            path.stroke()
        }
    }

    /// The view-space path for a mark. Separate from `AnnotationShape.boundingBox` so the
    /// pure logic stays free of AppKit and unit-testable.
    ///
    /// The view is flipped, so its y axis already matches `LogicalPoint`. Drawing a shape
    /// here and compositing the same shape into a screenshot share this convention, which
    /// is why the user sees the circle where they drew it rather than mirrored vertically.
    ///
    /// A pin has no path — it is filled, so `draw(_:)` paints it.
    static func path(for shape: AnnotationShape) -> NSBezierPath? {
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
        case .pin:
            return nil
        }
        return path
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        onActivity?()
        switch event.keyCode {
        case 36, 76:                                   // Return, Enter
            onSubmit?(session.shapes)
        case 53:                                        // Escape
            onCancel?("escape")
        case 51, 115:                                   // Backspace, forward delete
            undoLast()
        case 49:                                        // Space: cycle tool
            let all = Tool.allCases
            let index = all.firstIndex(of: tool) ?? 0
            tool = all[(index + 1) % all.count]
            updateHint("Tool: \(tool.rawValue) · Return to ask · Esc or right-click to cancel")
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
        // This used to be a flat `y = 14`, which in this flipped view is 14 pt from the *top* of
        // the display — behind the physical notch, so the middle of the sentence was cut off
        // (reported 2026-10-12). `safeAreaInsets.top` is the documented notch depth, so the hint
        // starts below the hardware; it is 0 on a notch-free display, where 14 is what was wanted
        // anyway. `window?.screen` is still nil this early on a panel that has not been ordered
        // front, hence the fallback to the display the HUD already attaches to.
        // Notch depth plus room for the menu-bar row, so the strip sits below the hardware *and*
        // below the clock rather than under either.
        let inset = hintTopInset
            ?? ((window?.screen ?? NotchAnchor.screen())?.safeAreaInsets.top ?? 0) + 22
        let width = min(520, bounds.width - 24)
        hint.frame = NSRect(x: bounds.midX - width / 2, y: inset, width: width, height: 26)
        updateHint(hintText
            ?? "Draw and speak — circle what you mean, say the question · Return · Esc to cancel")
    }

    private func updateHint(_ text: String) {
        toolHint?.stringValue = text
    }

    /// Replace the hint line while the surface is open — the way to tell the user the gesture needs
    /// something from him before Return means anything.
    func setHint(_ text: String) { updateHint(text) }
}

/// `Chunks --annotate-safety [seconds]` — prove the exits work before anything depends on them.
///
/// The order matters, and it is the order this feature failed in the first place: the drawing was
/// built, wired to a question, and shipped, and the dismissal was only ever tested by a human
/// pressing keys. This mode shows the surface with a short self-dismiss and nothing else — no
/// capture, no model call — so the single question asked of it is *does it let go*.
@MainActor
enum AnnotationSafetyProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--annotate-safety") }

    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        let idle = requestedIdle()
        guard let display = CaptureEngine.mainDisplay() else {
            print("annotate-safety: no main display")
            Log.flush()
            exit(1)
        }

        print("annotate-safety: overlay appears now and MUST disappear on its own after "
            + "\(Int(idle))s without input. Right-click to test that exit instead.")
        let window = AnnotationOverlayWindow(
            display: display,
            onSubmit: { shapes, _ in
                print("annotate-safety: submitted \(shapes.count) mark(s) — the keyboard exit worked")
                Log.write("annotate-safety: submitted \(shapes.count) mark(s)")
                Log.flush()
                exit(0)
            },
            idleLimitSeconds: idle,
            absoluteLimitSeconds: idle * 3)
        // The probe could not otherwise tell success from failure: the watchdog below fires at
        // `idle * 3 + 3` whether or not the overlay already went away, so a surface that dismissed
        // itself exactly on time still printed FAIL. Whoever leaves first gives the verdict.
        window.onDismissed = {
            print("annotate-safety: PASS — the overlay dismissed itself and the process left with it.")
            Log.write("annotate-safety: PASS — self-dismissed")
            Log.flush()
            exit(0)
        }
        window.show()

        // If the surface is gone, the process leaving with it is the proof. If this fires while the
        // overlay is still visible, the auto-dismiss failed and that is the bug to fix first.
        DispatchQueue.main.asyncAfter(deadline: .now() + idle * 3 + 3) {
            print("annotate-safety: FAIL — the overlay is still on screen after its absolute limit.")
            Log.write("annotate-safety: FAIL — still visible after \(Int(idle * 3))s")
            Log.flush()
            exit(1)
        }
        // No `dispatchMain()` here: `start()` runs the application, and a second drain of the main
        // queue from inside the first would park the thread before the application ever started.
    }

    /// Start on the main thread and never return.
    ///
    /// `run()` builds an `NSWindow`, so it has to be on the main *thread* — and in a shell-launched
    /// process the main actor is a pool thread until `NSApplication` runs, which is why the hop here
    /// is a dispatch onto the main queue plus the application's own run loop rather than a
    /// `Task { @MainActor }`: that task built the panel on a pool thread and AppKit refused it with
    /// "NSWindow should only be instantiated on the main thread". `App.init` has no guarantee it runs
    /// on main, hence the guard.
    static func start() -> Never {
        guard Thread.isMainThread else {
            print("annotate-safety: not on the main thread at start — refusing to guess where AppKit is")
            Log.flush()
            exit(1)
        }
        DispatchQueue.main.async {
            Task { @MainActor in run() }
        }
        NSApplication.shared.run()
        // Unreachable: `run` never returns while the probe is alive, and the loop is what makes this
        // function's `Never` honest if it ever did.
        while true { Thread.sleep(forTimeInterval: 3600) }
    }

    private static func requestedIdle() -> Double {
        guard let index = CommandLine.arguments.firstIndex(of: "--annotate-safety") else { return 8 }
        let next = index + 1
        guard CommandLine.arguments.indices.contains(next),
              let parsed = Double(CommandLine.arguments[next]), parsed >= 2, parsed <= 120 else { return 8 }
        return parsed
    }
}
