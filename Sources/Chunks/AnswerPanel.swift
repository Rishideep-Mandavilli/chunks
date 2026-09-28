import AppKit
import ChunksKit

/// A model point the user can click to be shown where it is on screen.
struct PanelPoint: Equatable {
    let label: String
    let point: LogicalPoint
    /// Image pixel the model named, kept for display so the coordinates are checkable.
    let imagePixel: LogicalPoint
}

/// What the panel renders. One value, one re-render — simpler to reason about than
/// incremental mutations, and the content is small enough that it does not matter.
struct AnswerPanelContent: Equatable {
    enum Status: Equatable {
        case working(String)
        case ready
        case failed(String)
    }

    var status: Status = .working("Starting…")
    /// The `<SAY>` part. Large: this is the headline.
    var speech: String = ""
    /// Everything outside `<SAY>`. Smaller and secondary: the detail.
    var detail: String = ""
    var points: [PanelPoint] = []
    /// True while the model is still streaming, so the panel can show a cursor.
    var isStreaming: Bool = false

    var isEmpty: Bool { speech.isEmpty && detail.isEmpty && points.isEmpty }
}

/// The floating card that shows the answer.
///
/// Three properties matter more than how it looks:
///
/// 1. **It never takes focus.** `.nonactivatingPanel` plus `canBecomeKey == false` means the
///    user can keep typing in whatever they were typing in while Chunks answers. A panel
///    that steals focus is unusable — you would have to click back into your editor after
///    every question.
/// 2. **It does not block the screen.** `ignoresMouseEvents` is on until the pointer
///    actually enters the panel, so the card is invisible to clicks in the common case and
///    only becomes clickable when the user is evidently trying to use it.
/// 3. **It follows the user across Spaces and full-screen apps.** `canJoinAllSpaces` +
///    `fullScreenAuxiliary`, otherwise the answer would appear on a Space the user is not
///    looking at, which is the same as not appearing.
@MainActor
final class AnswerPanel {

    private var panel: NSPanel?
    private let view = AnswerPanelView()
    private var content = AnswerPanelContent()
    private var display: DisplayInfo?
    private var onReveal: ((LogicalPoint) -> Void)?

    private let width: CGFloat = AnswerPanelLayout.defaultWidth
    private let margin: CGFloat = 28
    private let innerInset = AnswerPanelLayout.inset

    // MARK: Lifecycle

    func show(on display: DisplayInfo, onReveal: @escaping (LogicalPoint) -> Void) {
        self.display = display
        self.onReveal = onReveal

        if panel == nil { makePanel() }
        view.onRevealPoint = { [weak self] point in
            self?.onReveal?(point)
            self?.flash(point: point)
        }
        view.content = content
        view.frame = CGRect(x: 0, y: 0, width: width, height: AnswerPanelLayout.minimumHeight)
        view.autoresizingMask = [.width]

        layout()
        panel?.orderFrontRegardless()
    }

    private func makePanel() {
        // `.floating` sits above ordinary windows but below the annotation overlay, so
        // drawing on the screen always covers the answer card.
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: width,
                                                height: AnswerPanelLayout.minimumHeight),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .floating
        // Near-opaque, not `clear`. The card sits over whatever the user is working in,
        // and at 0.92 the app behind showed through strongly enough to make the text hard
        // to read — a companion that is hard to read is worse than no card at all.
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.contentView = view
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: Content

    func update(_ transform: (inout AnswerPanelContent) -> Void) {
        let before = content
        transform(&content)
        guard !content.isEmpty || !isHidden else { return }
        // Skip the relayout when nothing the panel draws actually changed. A streaming turn
        // calls this on every delta, and most deltas are empty or mid-tag — a text
        // measurement and a `setFrame` per character is real work for no visible result.
        guard content != before else { return }
        view.content = content
        layout()
    }

    private var isHidden: Bool { panel?.isVisible != true }

    /// Bottom-centre of the display, clear of the Dock.
    ///
    /// Bottom-centre rather than top-right: the top-right is where menu bar extras live,
    /// which is the one place on a Mac that is always occupied, and the bottom edge is
    /// where the user's attention already is.
    private func layout() {
        guard let panel, let display else { return }

        // Single source of truth for the card's height, in ChunksKit so it is testable
        // without a window.
        // Measured on the same text that gets drawn. Sizing on unbounded detail while
        // drawing a bounded version is how a card ends up taller than it needs and the
        // chips slide toward the bottom edge.
        let height = AnswerPanelLayout.measure(speech: content.speech,
                                               detail: AnswerPanelLayout.boundedDetail(content.detail),
                                               pointCount: content.points.count,
                                               width: width,
                                               inset: innerInset)

        // Bottom-centre, inside the display's own frame so a second monitor to the left
        // (negative origin) places the card on the display it belongs to.
        let y = display.frame.minY + margin
        let x = display.frame.minX + (display.frame.width - width) / 2

        panel.setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.needsDisplay = true
    }

    /// A brief pulse on a point chip after the user clicks it, so the click registers even
    /// though the card is click-through most of the time.
    private func flash(point: LogicalPoint) {
        view.flash(point: point)
        CursorAnimator.fly(to: point)
    }
}

// MARK: - The view

/// Draws the card. Plain AppKit rather than SwiftUI: it is a borderless non-key panel that
/// needs precise control over mouse-through behaviour, and SwiftUI's hosting layer brings
/// a key-window relationship this explicitly must not have.
@MainActor
final class AnswerPanelView: NSView {

    var onRevealPoint: ((LogicalPoint) -> Void)?

    /// The panel owns this value; `AnswerPanel` sets it, the view only reads it.
    fileprivate(set) var content = AnswerPanelContent()

    /// Index of the chip that is briefly highlighted after a click, or `nil`.
    private var highlighted: Int?
    private var tracking: NSTrackingArea?

    /// Where the chips were actually drawn, recorded during `draw` so hover and click
    /// hit-testing use the same rects the user can see.
    private var chipFrames: [CGRect] = []

    var speechText: String { content.speech }
    var detailText: String { content.detail }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        tracking = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(tracking!)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    // MARK: Mouse-through

    override func mouseEntered(with event: NSEvent) {
        // Only become clickable when the pointer is actually over the card. Everywhere
        // else the window ignores mouse events entirely, so it cannot intercept a click
        // meant for the app underneath.
        window?.ignoresMouseEvents = false
    }

    override func mouseExited(with event: NSEvent) {
        window?.ignoresMouseEvents = true
    }

    // MARK: Layout

    /// Detail as it should be rendered, bounded so the card cannot be swamped.
    private var renderedDetail: String {
        AnswerPanelLayout.boundedDetail(content.detail)
    }

    /// Fonts and metrics. The values themselves live in `AnswerPanelLayout` so the panel
    /// and the tests agree on what "one line" costs.
    static let speechFont = AnswerPanelLayout.speechFont
    static let detailFont = AnswerPanelLayout.detailFont
    static let speechLineHeight = AnswerPanelLayout.speechLineHeight
    static let detailLineHeight = AnswerPanelLayout.detailLineHeight
    static let chipHeight = AnswerPanelLayout.chipHeight
    static let inset = AnswerPanelLayout.inset

    private let inset = AnswerPanelView.inset
    private var rowHeight: CGFloat = AnswerPanelView.chipHeight

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds

        // Background via the layer rather than a drawn path. `masksToBounds` is what clips
        // overflow: a reply taller than the card's maximum would otherwise draw its text and
        // point chips straight past the rounded corners and onto the desktop.
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.985).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        layer?.borderWidth = 1

        // Uses the same constants and the same order as `AnswerPanelLayout.measure`. Keeping
        // the two in step is the point: when the drawn layout and the card's height are
        // computed independently they drift, and the drift only ever shows up as text
        // sitting on top of a point chip on a real screen.
        var y: CGFloat = inset
        let width = rect.width - inset * 2

        y = drawStatus(at: NSPoint(x: inset, y: y), width: width)

        if !content.speech.isEmpty {
            y = drawSpeech(at: NSPoint(x: inset, y: y), width: width)
            y += AnswerPanelLayout.sectionGap
        }
        let detail = renderedDetail
        if !detail.isEmpty {
            y = drawDetail(detail, at: NSPoint(x: inset, y: y), width: width)
            y += AnswerPanelLayout.chipGap
        }
        if !content.points.isEmpty {
            drawPoints(at: NSPoint(x: inset, y: y), width: width)
        }
    }

    private func drawStatus(at origin: NSPoint, width: CGFloat) -> CGFloat {
        let (text, colour, symbol): (String, NSColor, String) = {
            switch content.status {
            case .working(let message): return (message, .secondaryLabelColor, "hourglass")
            case .ready: return (content.isStreaming ? "Answering…" : "Done",
                                 .secondaryLabelColor, "checkmark.circle")
            case .failed(let message): return (message, .systemRed, "exclamationmark.triangle")
            }
        }()

        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        icon?.isTemplate = true
        icon?.draw(in: NSRect(x: origin.x, y: origin.y + 2, width: 13, height: 13))

        // Elided: a long failure message must not run off the card, and the full text is
        // in the menu where it can be read at leisure.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: NSRect(x: origin.x + 18, y: origin.y,
                                           width: width - 18, height: 16),
                               withAttributes: [
                                   .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                   .foregroundColor: colour,
                                   .paragraphStyle: paragraph,
                               ])
        return AnswerPanelLayout.statusRowHeight
    }

    private func drawSpeech(at origin: NSPoint, width: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.speechFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let height = (content.speech as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil).height

        (content.speech as NSString).draw(
            with: CGRect(x: origin.x, y: origin.y, width: width, height: height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil)

        // Rounded **up to a whole line**, not merely to the next pixel.
        //
        // `measure` reserves `lines * speechLineHeight`, which is never less than the
        // measured height, so advancing by the raw pixel height keeps the two in step. A
        // pixel-rounding slip here is what let a point chip land on the headline's last
        // line — invisible in the maths, obvious on screen.
        return ceil(height / Self.speechLineHeight) * Self.speechLineHeight
    }

    private func drawDetail(_ detail: String, at origin: NSPoint, width: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.detailFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let height = (detail as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil).height

        (detail as NSString).draw(
            with: CGRect(x: origin.x, y: origin.y, width: width, height: height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil)
        return ceil(height / Self.detailLineHeight) * Self.detailLineHeight
    }

    private func drawPoints(at origin: NSPoint, width: CGFloat) {
        var y = origin.y
        let pointer = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        chipFrames = []

        for (index, point) in content.points.enumerated() {
            let chip = NSRect(x: origin.x, y: y, width: width, height: 22)
            chipFrames.append(chip)

            // Brighter on hover, so the click target is discoverable without a pointer
            // change. The card ignores mouse events until the pointer enters, so this
            // highlight is also the only affordance saying "you can click this".
            let isHovered = chip.contains(pointer)
            let background = index == highlighted
                ? NSColor.controlAccentColor.withAlphaComponent(0.35)
                : (isHovered
                    ? NSColor.labelColor.withAlphaComponent(0.10)
                    : NSColor.labelColor.withAlphaComponent(0.05))
            background.setFill()
            NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()

            let icon = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)
            icon?.isTemplate = true
            icon?.draw(in: NSRect(x: chip.minX + 6, y: chip.minY + 5, width: 12, height: 12))

            let title = point.label.isEmpty ? "point" : point.label
            let detail = "  \(Int(point.imagePixel.x)), \(Int(point.imagePixel.y)) in image"
            let text = NSMutableAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])
            text.append(NSAttributedString(string: detail, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            text.draw(in: chip.insetBy(dx: 22, dy: 4))

            y += rowHeight
        }
    }

    /// The band of the view occupied by the point chips, in flipped view coordinates.
    ///
    /// Derived from `chipFrames` — the rects `draw` actually used — so hover and
    /// hit-testing cannot disagree with what is on screen. The first version computed the
    /// band from the bottom of the view while `draw` placed the chips top-down, so hover
    /// lit the wrong strip and clicks never landed.
    private var chipBand: CGRect {
        guard let first = chipFrames.first, let last = chipFrames.last else { return .zero }
        return first.union(last)
    }

    override func mouseUp(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        // Hit-test against the rects `draw` used, not a recomputed band.
        guard let row = chipFrames.firstIndex(where: { $0.contains(local) }) else { return }
        guard content.points.indices.contains(row) else { return }
        onRevealPoint?(content.points[row].point)
    }

    /// Brief highlight pulse, so a click is acknowledged even though the card is
    /// normally click-through.
    func flash(point: LogicalPoint) {
        guard let index = content.points.firstIndex(where: { $0.point == point }) else { return }
        highlighted = index
        needsDisplay = true

        // Clear the highlight after a beat. Not a repeating animation: the panel is not
        // the focus of attention, and a pulsing card would compete with the app the user
        // went back to.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.highlighted = nil
            self.needsDisplay = true
        }
    }
}
