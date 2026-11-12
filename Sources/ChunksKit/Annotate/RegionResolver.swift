import CoreGraphics
import Foundation

/// The palette the agent may draw with. The user's own overlay stays the single warm red; the agent
/// can pick a colour per mark so a multi-part explanation reads as separate, legible strokes rather
/// than one monochrome scribble.
public enum InkColor: String, CaseIterable, Sendable {
    case red, blue, green, orange, purple, yellow, pink, teal, white, black
    case brown, gray, cyan, magenta, gold, navy, lime, maroon, violet

    public var cgColor: CGColor {
        switch self {
        case .red:    return CGColor(srgbRed: 1.00, green: 0.24, blue: 0.32, alpha: 1)
        case .blue:   return CGColor(srgbRed: 0.15, green: 0.45, blue: 1.00, alpha: 1)
        case .green:  return CGColor(srgbRed: 0.15, green: 0.70, blue: 0.35, alpha: 1)
        case .orange: return CGColor(srgbRed: 1.00, green: 0.55, blue: 0.10, alpha: 1)
        case .purple: return CGColor(srgbRed: 0.60, green: 0.30, blue: 0.95, alpha: 1)
        case .yellow: return CGColor(srgbRed: 0.98, green: 0.80, blue: 0.10, alpha: 1)
        case .pink:   return CGColor(srgbRed: 1.00, green: 0.40, blue: 0.70, alpha: 1)
        case .teal:   return CGColor(srgbRed: 0.10, green: 0.70, blue: 0.70, alpha: 1)
        case .white:  return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .black:  return CGColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1)
        case .brown:  return CGColor(srgbRed: 0.55, green: 0.35, blue: 0.15, alpha: 1)
        case .gray:   return CGColor(srgbRed: 0.50, green: 0.50, blue: 0.50, alpha: 1)
        case .cyan:   return CGColor(srgbRed: 0.10, green: 0.80, blue: 0.90, alpha: 1)
        case .magenta:return CGColor(srgbRed: 0.90, green: 0.20, blue: 0.80, alpha: 1)
        case .gold:   return CGColor(srgbRed: 0.85, green: 0.65, blue: 0.10, alpha: 1)
        case .navy:   return CGColor(srgbRed: 0.10, green: 0.20, blue: 0.50, alpha: 1)
        case .lime:   return CGColor(srgbRed: 0.60, green: 0.90, blue: 0.20, alpha: 1)
        case .maroon: return CGColor(srgbRed: 0.50, green: 0.10, blue: 0.15, alpha: 1)
        case .violet: return CGColor(srgbRed: 0.50, green: 0.20, blue: 0.80, alpha: 1)
        }
    }

    public static func parse(_ raw: String) -> InkColor? {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if name == "grey" { return .gray }
        return InkColor(rawValue: name)
    }
}

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
    case pin(LogicalPoint)
    /// A straight line, tail to head (an arrow without the head).
    case line(from: LogicalPoint, to: LogicalPoint)
    /// A translucent filled box — "this region", without a hard outline.
    case highlight(LogicalRect)
    /// A line under a region — "this text".
    case underline(LogicalRect)
    /// Words written on the screen at a point (top-left anchor). Emoji render as real glyphs.
    case text(LogicalPoint, String)
    /// A freeform polyline through the given points — the agent's pen for anything the named shapes
    /// cannot say (a smile, a heart, a star, a squiggle). Smoothed when rendered.
    case path([LogicalPoint])
    /// An elliptical arc, angles in degrees (0 = right, increasing toward the bottom in the flipped
    /// view), for smiles and curves.
    case arc(center: LogicalPoint, radiusX: Double, radiusY: Double, start: Double, end: Double)
    /// A mark drawn in a specific colour; the geometry is the inner shape.
    indirect case tinted(AnnotationShape, InkColor)

    /// The context a pin carries into a crop, in logical points.
    public static let pinRadius: Double = 24
    /// The radius of the dot a pin is drawn as.
    public static let pinDotRadius: Double = 5
    public static let pinRingGap: Double = 1.5
    public static let pinRingWidth: Double = 2
    public static var pinDrawnRadius: Double { pinDotRadius + pinRingGap + pinRingWidth }
    /// The size of written words, in logical points.
    public static let textSize: Double = 22

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

        case .line(let from, let to):
            let pad = AnnotationShape.strokeWidth
            let minX = Swift.min(from.x, to.x) - pad
            let minY = Swift.min(from.y, to.y) - pad
            let maxX = Swift.max(from.x, to.x) + pad
            let maxY = Swift.max(from.y, to.y) + pad
            return LogicalRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        case .highlight(let r), .underline(let r):
            let pad = AnnotationShape.strokeWidth
            return LogicalRect(x: r.minX - pad, y: r.minY - pad,
                               width: r.width + pad * 2, height: r.height + pad * 2)

        case .text(let point, let words):
            // A generous estimate so a crop around written words is never smaller than the words.
            let width = Double(words.count) * AnnotationShape.textSize * 0.62
            return LogicalRect(x: point.x, y: point.y,
                               width: Swift.max(width, AnnotationShape.textSize),
                               height: AnnotationShape.textSize * 1.4)

        case .path(let points):
            guard let first = points.first else { return LogicalRect(x: 0, y: 0, width: 0, height: 0) }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points {
                minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
                minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
            }
            let pad = AnnotationShape.strokeWidth
            return LogicalRect(x: minX - pad, y: minY - pad,
                               width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)

        case .arc(let center, let rx, let ry, _, _):
            let pad = AnnotationShape.strokeWidth
            return LogicalRect(x: center.x - rx - pad, y: center.y - ry - pad,
                               width: (rx + pad) * 2, height: (ry + pad) * 2)

        case .tinted(let inner, _):
            return inner.boundingBox
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
    public mutating func erase(at point: LogicalPoint) -> Bool {
        for index in shapes.indices.reversed() {
            if shapes[index].boundingBox.contains(point) {
                shapes.remove(at: index)
                return true
            }
        }
        return false
    }

    /// The mark under a point, without removing it — the same rule the eraser uses.
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
            case .line: noun = "lined"
            case .highlight: noun = "highlighted"
            case .underline: noun = "underlined"
            case .text: noun = "wrote on"
            case .path: noun = "drew"
            case .arc: noun = "curved"
            case .tinted(let inner, _):
                noun = AnnotationSession(shapes: [inner]).descriptionForModel
                    .replacingOccurrences(of: "1 region ", with: "")
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
