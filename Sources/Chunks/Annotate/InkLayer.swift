import AppKit
import ChunksKit

/// The marks he drew, left on the screen while Chunks answers about them.
///
/// The drawing surface closes the moment he presses Return, and the turn that follows lasts seconds —
/// so without this, "the button you circled" is a sentence about a mark that has already gone. The
/// answer arrives pointing at nothing he can see, and the only way to check it is to draw the circle
/// again. This keeps the ink where he put it until the answer lands.
///
/// It is the opposite of the overlay in every property that matters, and each one is a lesson this
/// codebase paid for:
///
/// - **It receives nothing.** `ignoresMouseEvents` is true, it can never become key or main, and
///   `_setPreventsActivation` keeps Chunks out of the app switcher and his app in the menu bar. A
///   display-sized window that *takes* the mouse is what locked his Mac on 2026-10-11; a window that
///   cannot take a click cannot hold him, which is the structural reason this surface is allowed to
///   exist at all while the overlay needs three exits and a watchdog.
/// - **It does not shade the screen.** The overlay dims 18% because a transparent surface gives no
///   sign the gesture is live. Here the gesture is over and he is meant to keep working: a tint over
///   a live desktop would be a second overlay, and it would be covering the very thing the answer is
///   about.
/// - **It cannot outlive the turn.** It is cleared when the card reports an answer or a failure, when
///   the card is dismissed, and by its own absolute limit, whichever comes first — the same belt and
///   braces the overlay has, because stale red marks on his desktop are worse than none: they would
///   be pointing at whatever moved underneath them.
/// - **It is in no picture.** The marks reach the model burned into the crop by `CaptureEngine`,
///   which is where they belong. A live layer that also landed in a screenshot would give the model
///   two copies of the same ink, one of them over the real screen. The whole-screen capture path
///   already excludes every window this app owns; this panel also sets `sharingType = .none` so the
///   unfiltered rect capture cannot see it either — measured, not assumed, by `--probe-ink`.
@MainActor
final class InkLayerManager {

    /// The cap, when nothing else cleared it. Well past a full turn's 60 s budget plus its acts, and
    /// well short of "forgotten". `nonisolated` because it is the default argument of `show`, which a
    /// caller reads from outside the main actor.
    nonisolated static let absoluteLimitSeconds: TimeInterval = 120

    private var panel: InkPanel?
    private var view: InkView?
    private var limitTimer: Timer?
    private(set) var shapes: [AnnotationShape] = []

    /// Whether ink is on screen. Read by the probe and by the safety gate, never inferred.
    var isShowing: Bool { panel?.isVisible == true }

    /// The window the ink is drawn in, so a probe can ask it the four questions that keep this
    /// surface from becoming the overlay's bug.
    var window: NSWindow? { panel }

    /// Put his marks back on the display they were drawn on.
    ///
    /// False when the display matches no screen: ink on the wrong monitor is worse than no ink,
    /// because the marks would sit over a desktop that is not the one the crop came from.
    @discardableResult
    func show(_ shapes: [AnnotationShape],
              on display: DisplayInfo,
              limitSeconds: TimeInterval = InkLayerManager.absoluteLimitSeconds) -> Bool {
        clear(reason: "replaced by a new drawing")
        guard !shapes.isEmpty else { return false }
        guard let screen = DisplayScreens.matching(display) else {
            Log.write("ink: refused — display \(display.displayID) matches no NSScreen "
                + "(screens=\(NSScreen.screens.count))")
            return false
        }
        return present(shapes, frame: screen.frame, limitSeconds: limitSeconds,
                       label: "display \(display.displayID)")
    }

    /// Put marks on a display given its AppKit frame — the shell has the capture's frame, not a
    /// `DisplayInfo`. Shapes are display-local top-left logical points.
    @discardableResult
    func show(_ shapes: [AnnotationShape],
              in frame: CGRect,
              limitSeconds: TimeInterval = InkLayerManager.absoluteLimitSeconds) -> Bool {
        present(shapes, frame: frame, limitSeconds: limitSeconds, label: "frame \(Int(frame.width))x\(Int(frame.height))")
    }

    private func present(_ shapes: [AnnotationShape], frame: CGRect,
                         limitSeconds: TimeInterval, label: String) -> Bool {
        clear(reason: "replaced by a new drawing")
        guard !shapes.isEmpty else { return false }

        let panel = InkPanel(contentRect: frame,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered,
                             defer: false)
        // Above ordinary windows, below the notch card: the ink restates what the card is answering,
        // and it must never cover a question he has to answer.
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Not `.canJoinAllSpaces`: the ink belongs to the turn, on the display it was drawn on, and
        // following him to another Space would be marks over a screen they were never about.
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The line that makes the window inert. Without it AppKit treats a mouse-down here as an
        // attempt to activate Chunks and swallows the click — the failure the overlay spent eleven
        // rounds on, and here it would be a click stolen from whatever he was doing.
        panel.ignoresMouseEvents = true
        // Not public API, and guarded for the same reason the overlay guards it: if it disappears,
        // this layer loses a guarantee and nothing else, because the click-through above still holds.
        let preventsActivation = NSSelectorFromString("_setPreventsActivation:")
        let guarded = panel.responds(to: preventsActivation)
        if guarded { panel.perform(preventsActivation, with: NSNumber(value: true)) }
        // Keeps these marks out of any capture that does not already exclude this app's windows.
        panel.sharingType = .none

        // Content-local frame, not the screen's global one: a view's origin inside its own window is
        // (0,0), and the view is flipped, so its points are the display-local top-left points the
        // marks were drawn in. The same convention the overlay's canvas uses, which is why nothing
        // here converts anything.
        let view = InkView(frame: NSRect(x: 0, y: 0, width: frame.width,
                                         height: frame.height))
        view.shapes = shapes
        panel.contentView = view

        self.panel = panel
        self.view = view
        self.shapes = shapes
        panel.orderFrontRegardless()

        limitTimer = Timer.scheduledTimer(withTimeInterval: limitSeconds, repeats: false) {
            [weak self] _ in
            // Hopped, never asserted: being on the main thread is not being on the main actor's
            // executor, and that assertion in a timer block is what killed the app on 2026-11-03.
            Task { @MainActor [weak self] in
                self?.clear(reason: "reached its time limit")
            }
        }
        Log.write("ink: \(shapes.count) mark(s) left on \(label) for "
            + "\(Int(limitSeconds))s — clickThrough=\(panel.ignoresMouseEvents) "
            + "activation guard=\(guarded)")
        return true
    }

    /// Take the ink down. Safe to call when nothing is up, and always says why: an unexplained
    /// disappearance is the same class of invisible event the overlay's dismissal log was added for.
    func clear(reason: String) {
        limitTimer?.invalidate()
        limitTimer = nil
        guard let panel else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        view = nil
        shapes = []
        Log.write("ink: cleared — \(reason)")
    }
}

/// A panel that can never take the keyboard or the mouse.
///
/// Both halves are needed and they do different jobs: `ignoresMouseEvents` sends the click through to
/// whatever is behind, while `canBecomeKey` false is what stops a click *anywhere* in Chunks from
/// routing focus here and leaving his text field. `canBecomeMain` false keeps his app in the menu bar.
final class InkPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The marks themselves, and nothing else.
///
/// Flipped, so its y axis already matches `LogicalPoint`'s top-left convention — the same view
/// orientation the drawing surface uses, which is why a mark lands where he drew it rather than
/// mirrored vertically.
final class InkView: NSView {

    var shapes: [AnnotationShape] = [] {
        didSet { needsDisplay = true }
    }

    /// Filled behind the marks. Only the render probe sets it, so the ink has something to be seen
    /// against in a PNG; the live layer leaves it nil because his desktop is the backdrop.
    var backdrop: NSColor?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // `bounds`, not `dirtyRect`, for the backdrop: a partial fill would leave a patch of desktop
        // showing through the middle of the render.
        if let backdrop {
            backdrop.setFill()
            bounds.fill()
        }
        for shape in shapes {
            AnnotationCanvas.draw(shape)
        }
    }
}

/// The `NSScreen` behind a display, matched by its ID.
///
/// One place, because the two coordinate systems differ by their origin — `CGDisplayBounds` is
/// top-left, `NSScreen.frame` bottom-left — and array order is not identity. A window placed from the
/// wrong one lands on the wrong screen the moment a second display is plugged in, which is invariant
/// 1's oldest trap.
enum DisplayScreens {

    static func matching(_ display: DisplayInfo) -> NSScreen? {
        matching(display.displayID)
    }

    static func matching(_ displayID: CGDirectDisplayID) -> NSScreen? {
        for screen in NSScreen.screens {
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? NSNumber)?.uint32Value
            if number == displayID { return screen }
        }
        return nil
    }
}
