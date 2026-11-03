import CoreGraphics
import Foundation

/// One mark the user drew on the overlay.
public enum AnnotationShape: Equatable, Sendable {
    /// Freehand pen. Stored as sampled points, not a `CGPath`, so it stays `Sendable` and
    /// comparable in tests.
    case stroke([LogicalPoint])
    /// A circle or ellipse. Drawn by dragging from one corner to the other.
    case ellipse(center: LogicalPoint, radiusX: Double, radiusY: Double)
    /// A rectangle, used for highlighting.
    case rect(LogicalRect)
    /// An arrow, drawn from tail to head.
    case arrow(from: LogicalPoint, to: LogicalPoint)
    /// A pin: one point, marked, with no extent of its own.
    ///
    /// The other four shapes are *regions* — they say "this area". A pin says "this exact thing", which
    /// is what "explain the button I just put a dot on" needs and what a circle cannot say without the
    /// model guessing which part of the circle he meant. Its bounding box is a small disc rather than a
    /// point, because a pin that dragged the session's crop down to 1x1 would hand the model a picture
    /// of nothing.
    case pin(LogicalPoint)

    /// The context a pin carries into a crop, in logical points.
    ///
    /// Deliberately much wider than the dot that is drawn (`pinDotRadius`): it is the crop's padding
    /// *and* the eraser's reach, and an eraser that only removed a pin when he hit five points of
    /// solid red exactly would be a tool he has to aim at with the thing he is aiming at.
    public static let pinRadius: Double = 24

    /// The radius of the dot a pin is drawn as, in logical points.
    ///
    /// Pure, and shared by the three places a pin appears — the drawing surface, the layer that keeps
    /// the marks on screen while the turn runs, and the burn-in that paints them into the picture the
    /// model reads. Three copies of one number is three chances for "the thing I pinned" to mean a
    /// dot on his screen and a ring in the crop.
    public static let pinDotRadius: Double = 5

    /// The pale ring just outside the dot, which is what keeps a pin legible on a dark wallpaper.
    public static let pinRingGap: Double = 1.5
    public static let pinRingWidth: Double = 2

    /// The whole drawn mark's radius: dot, gap and ring.
    public static var pinDrawnRadius: Double { pinDotRadius + pinRingGap + pinRingWidth }

    /// The smallest rect containing the mark, in display-local logical points.
    public var boundingBox: LogicalRect {
        switch self {
        case .stroke(let points):
            guard let first = points.first else { return LogicalRect(x: 0, y: 0, width: 0, height: 0) }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points {
                minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
                minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
            }
            return LogicalRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        case .ellipse(let center, let radiusX, let radiusY):
            // Pad by the stroke width so the ring itself is inside the crop.
            let pad = AnnotationShape.strokeWidth
            return LogicalRect(x: center.x - radiusX - pad, y: center.y - radiusY - pad,
                               width: (radiusX + pad) * 2, height: (radiusY + pad) * 2)

        case .rect(let r):
            let pad = AnnotationShape.strokeWidth
            return LogicalRect(x: r.minX - pad, y: r.minY - pad,
                               width: r.width + pad * 2, height: r.height + pad * 2)

        case .arrow(let from, let to):
            let pad = AnnotationShape.strokeWidth
            let minX = Swift.min(from.x, to.x) - pad
            let minY = Swift.min(from.y, to.y) - pad
            let maxX = Swift.max(from.x, to.x) + pad
            let maxY = Swift.max(from.y, to.y) + pad
            return LogicalRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        case .pin(let point):
            let radius = AnnotationShape.pinRadius
            return LogicalRect(x: point.x - radius, y: point.y - radius,
                               width: radius * 2, height: radius * 2)
        }
    }

    /// Visual weight of the pen. Not a hairline: a thin line disappears in the crop and
    /// leaves the model looking at an unmarked screenshot.
    public static let strokeWidth: Double = 3

    /// Colour the marks are burned into the screenshot with.
    ///
    /// A saturated warm red rather than a UI accent: it is the colour the user's cursor and
    /// selection are *not*, it survives PNG compression without fringing, and it is the one
    /// colour virtually no application chrome uses for its own controls — so a highlight
    /// cannot be mistaken for part of the interface being explained.
    public static let overlayStrokeColor: CGColor = CGColor(
        srgbRed: 1.0, green: 0.24, blue: 0.32, alpha: 1.0)
}

/// The marks of one annotation session.
public struct AnnotationSession: Equatable, Sendable {
    public private(set) var shapes: [AnnotationShape] = []

    public init() {}
    public init(shapes: [AnnotationShape]) { self.shapes = shapes }

    public var isEmpty: Bool { shapes.isEmpty }

    public mutating func add(_ shape: AnnotationShape) { shapes.append(shape) }

    /// Undo the most recent mark.
    public mutating func undo() {
        if !shapes.isEmpty { shapes.removeLast() }
    }

    public mutating func clear() { shapes.removeAll() }

    /// Remove the mark under a point, topmost first, and say whether anything went.
    ///
    /// Topmost first because that is the one he can see on top of the others, and the one he means when
    /// he rubs at a pile of ink. Hit-testing is by bounding box rather than by distance to the stroke's
    /// own pixels: a freehand line is a sampled polyline, and the honest question at this scale is
    /// "which mark did he touch", not "which pixel of which mark", and a box test answers the first one
    /// without a nearest-segment search over every point of every stroke.
    public mutating func erase(at point: LogicalPoint) -> Bool {
        for index in shapes.indices.reversed() {
            if shapes[index].boundingBox.contains(point) {
                shapes.remove(at: index)
                return true
            }
        }
        return false
    }

    /// The mark under a point, without removing it — the same rule the eraser uses, so the two cannot
    /// disagree about what "under" means.
    public func shape(at point: LogicalPoint) -> AnnotationShape? {
        shapes.last { $0.boundingBox.contains(point) }
    }

    public var boundingBox: LogicalRect? {
        guard let first = shapes.first?.boundingBox else { return nil }
        return shapes.dropFirst().reduce(first) { $0.union($1.boundingBox) }
    }

    /// Human-readable description of the marks, given to the model so it knows the user
    /// annotated rather than merely cropped.
    ///
    /// Deliberately describes *intent-neutral* facts ("circled", "drew over") rather than
    /// guessing meaning — the model should read the picture, not the description.
    public var descriptionForModel: String {
        var counts: [String: Int] = [:]
        for shape in shapes {
            let noun: String
            switch shape {
            case .stroke: noun = "drew over"
            case .ellipse: noun = "circled"
            case .rect: noun = "boxed"
            case .arrow: noun = "pointed at"
            case .pin: noun = "pinned"
            }
            counts[noun, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }
            .map { "\($0.value) region\($0.value == 1 ? "" : "s") \($0.key)" }
            .joined(separator: ", ")
    }
}

// MARK: - Region resolution

/// Turns drawn marks into the crop region Chunks sends to the model.
public enum RegionResolver {

    /// Extra context around the marks.
    ///
    /// Not zero: a tight crop of a button gives the model no surrounding UI, so it cannot
    /// tell a toolbar button from a list row. This is the amount of "where am I" that
    /// makes a local explanation possible.
    public static let contextMargin: Double = 48

    /// Minimum crop size, so a tiny accidental dot still produces something usable.
    public static let minimumSize: LogicalSize = LogicalSize(width: 160, height: 120)

    /// The region to crop, in **display-local logical points**.
    ///
    /// - No marks: the whole display.
    /// - Marks present: their union box, padded, floored to `minimumSize`, clamped to the
    ///   display.
    public static func resolve(shapes: [AnnotationShape],
                               displaySize: LogicalSize,
                               margin: Double = contextMargin,
                               minimum: LogicalSize = minimumSize) -> LogicalRect {

        guard let union = AnnotationSession(shapes: shapes).boundingBox else {
            return LogicalRect(x: 0, y: 0, width: displaySize.width, height: displaySize.height)
        }

        // Grow around the centre so a box at the screen edge pads inward, not outward.
        let centreX = union.midX
        let centreY = union.midY
        var width = Swift.max(minimum.width, union.width + margin * 2)
        var height = Swift.max(minimum.height, union.height + margin * 2)

        // Never exceed the display.
        width = Swift.min(width, displaySize.width)
        height = Swift.min(height, displaySize.height)

        var x = centreX - width / 2
        var y = centreY - height / 2
        x = Swift.min(Swift.max(0, x), displaySize.width - width)
        y = Swift.min(Swift.max(0, y), displaySize.height - height)

        return LogicalRect(x: x, y: y, width: width, height: height)
    }

    /// Convenience for a whole-screen turn.
    public static func wholeScreen(displaySize: LogicalSize) -> LogicalRect {
        LogicalRect(x: 0, y: 0, width: displaySize.width, height: displaySize.height)
    }
}
