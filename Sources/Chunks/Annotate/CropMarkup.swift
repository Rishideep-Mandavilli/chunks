import AppKit
import ChunksKit

/// A frozen crop of the screen that the user draws on, in an ordinary panel.
///
/// This exists because a display-sized Chunks window cannot be given the mouse on this machine, and
/// three levels were measured failing three different ways: frontmost and key at `.screenSaver` with
/// no mouse event reaching the app at all; the click routed to another window at `.statusBar`; and a
/// level-1000 Chunks surface still listed by the window server after AppKit had ordered it out
/// (2026-10-15). A normal panel is the one shape this app already gets clicks on — the notch card and
/// the menu panel both take his buttons at `.statusBar`.
///
/// So the gesture is two steps: macOS picks the region with its own crosshair, which always owns the
/// pointer, and Chunks marks up the image that comes back. Nothing of ours covers the desktop while
/// he draws, which makes the 2026-10-11 lockup unreachable from this path even if the panel misbehaves.
@MainActor
final class CropMarkupWindow: NSObject, NSWindowDelegate {

    /// A panel the user walked away from must not keep holding the keyboard. Shorter than the
    /// full-screen surface's limit because there is a real image to look at and mark in one pass.
    nonisolated static let idleLimitSeconds: TimeInterval = 45
    nonisolated static let absoluteLimitSeconds: TimeInterval = 180

    private let png: Data
    private let pixelSize: NSSize
    private let onSubmit: (Data) -> Void
    private let onCancel: () -> Void
    private let canvas = AnnotationCanvas()
    private var panel: NSPanel?
    private var idleTimer: Timer?
    private var absoluteTimer: Timer?
    private var isClosed = false

    init?(png: Data, pixelSize: NSSize, onSubmit: @escaping (Data) -> Void,
          onCancel: @escaping () -> Void) {
        guard pixelSize.width > 0, pixelSize.height > 0, NSImage(data: png) != nil else { return nil }
        self.png = png
        self.pixelSize = pixelSize
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        super.init()
    }

    /// Fit the crop on screen at up to 72% of the visible area, centred, and hand it to the canvas.
    func show(on screen: NSScreen) {
        let available = screen.visibleFrame
        let fit = min(available.width * 0.72 / pixelSize.width,
                      available.height * 0.72 / pixelSize.height)
        let size = NSSize(width: max(320, pixelSize.width * fit),
                          height: max(200, pixelSize.height * fit))

        let created = AnnotationPanel(
            contentRect: NSRect(x: available.midX - size.width / 2,
                                y: available.midY - size.height / 2,
                                width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        created.isFloatingPanel = true
        created.level = .statusBar
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        created.isOpaque = true
        created.backgroundColor = .black
        created.hasShadow = true
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        created.delegate = self
        created.acceptsMouseMovedEvents = true

        // The crop is rendered by an `NSImageView`, not painted by the canvas. Drawing an `NSImage`
        // into a flipped view does not preserve its orientation — measured 2026-10-15 against an
        // offscreen render of exactly that call, and the user's selected region came back mirrored,
        // which makes the whole gesture unreadable. The image view is the renderer AppKit itself gets
        // right; the canvas stays a transparent layer above it, holding only the marks.
        let stage = NSView(frame: NSRect(origin: .zero, size: size))
        let still = NSImageView(frame: stage.bounds)
        still.image = NSImage(data: png)
        still.imageScaling = .scaleAxesIndependently
        still.imageFrameStyle = .none
        still.autoresizingMask = [.width, .height]
        stage.addSubview(still)

        canvas.frame = stage.bounds
        canvas.autoresizingMask = [.width, .height]
        canvas.hintTopInset = 10
        canvas.hintText = "Circle or arrow the part you mean · Return to ask · Esc to cancel"
        canvas.onSubmit = { [weak self] shapes in self?.submit(shapes) }
        canvas.onCancel = { [weak self] reason in self?.cancel(reason: reason) }
        canvas.onActivity = { [weak self] in self?.restartIdleTimer() }
        stage.addSubview(canvas)
        created.contentView = stage

        panel = created
        isClosed = false
        created.makeKeyAndOrderFront(nil)
        created.orderFrontRegardless()
        created.makeFirstResponder(canvas)
        restartIdleTimer()
        absoluteTimer = Timer.scheduledTimer(withTimeInterval: Self.absoluteLimitSeconds,
                                             repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cancel(reason: "reached its time limit") }
        }
        Log.write("annotate: markup open — \(Int(size.width))x\(Int(size.height))pt over a "
            + "\(Int(pixelSize.width))x\(Int(pixelSize.height))px crop, "
            + "auto-dismissing after \(Int(Self.idleLimitSeconds))s idle")
    }

    func dismissByChord() { cancel(reason: "chord pressed again") }

    private func submit(_ shapes: [AnnotationShape]) {
        guard !shapes.isEmpty else {
            // Stay open. Return with nothing on the crop is the user confirming what he selected, not
            // abandoning it — and closing without a word read as "Chunks ignored me", which is what
            // happened on the first real run of this panel (2026-10-15, 16:06:11).
            Log.write("annotate: Return with nothing drawn — the panel stays open")
            canvas.setHint("Draw on the crop first · Return to ask · Esc to cancel")
            return
        }
        guard close() else { return }
        guard let marked = flatten(shapes) else {
            Log.write("annotate: the marks could not be burned into the crop")
            onCancel()
            return
        }
        Log.write("annotate: \(shapes.count) mark(s) burned into \(Int(pixelSize.width))x"
            + "\(Int(pixelSize.height))px")
        onSubmit(marked)
    }

    /// Burn the marks in at the crop's own resolution.
    ///
    /// The crop is drawn into a bitmap rep Chunks created, not into the decoded one: a rep that came
    /// from PNG data cannot back a graphics context at all — `NSGraphicsContext(bitmapImageRep:)`
    /// returns nil for it, which is what made the first real run of this panel answer "the marks
    /// could not be burned into the crop" three times on 2026-10-15 while the pen worked perfectly.
    ///
    /// The canvas is flipped and the bitmap is not, so the marks go through a transform that moves
    /// the origin to the top-left and scales points into pixels in one step — which is also why the
    /// stroke width needs no special case: the CTM scales it with the image. Verified offscreen
    /// against a 100 pt view over a 100 px image: a stroke at view y = 20 lands on rows 18…21, and
    /// the crop itself renders upright.
    private func flatten(_ shapes: [AnnotationShape]) -> Data? {
        guard let source = NSBitmapImageRep(data: png),
              let image = NSImage(data: png),
              let target = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.pixelsWide,
                                            pixelsHigh: source.pixelsHigh, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                            bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
        let scale = CGFloat(target.pixelsHigh) / max(canvas.bounds.height, 1)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: target.pixelsWide, height: target.pixelsHigh))

        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: CGFloat(target.pixelsHigh))
        flip.scaleX(by: scale, yBy: -scale)
        flip.concat()
        for shape in shapes {
            AnnotationCanvas.draw(shape)
        }
        NSGraphicsContext.restoreGraphicsState()
        return target.representation(using: .png, properties: [:])
    }

    private func restartIdleTimer() {
        guard !isClosed else { return }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleLimitSeconds, repeats: false) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancel(reason: "no input for \(Int(Self.idleLimitSeconds))s")
            }
        }
    }

    @discardableResult
    private func cancel(reason: String) -> Bool {
        guard close() else { return false }
        Log.write("annotate: markup dismissed — \(reason)")
        onCancel()
        return true
    }

    @discardableResult
    private func close() -> Bool {
        guard !isClosed else { return false }
        isClosed = true
        idleTimer?.invalidate()
        idleTimer = nil
        absoluteTimer?.invalidate()
        absoluteTimer = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        return true
    }

    func windowWillClose(_ notification: Notification) { cancel(reason: "window closed") }
}
