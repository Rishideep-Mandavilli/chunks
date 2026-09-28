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
        }
    }

    /// Visual weight of the pen. Not a hairline: a thin line disappears in the crop and
    /// leaves the model looking at an unmarked screenshot.
    public static let strokeWidth: Double = 3
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

    /// Convert a resolved region into the pixel rect for cropping a screenshot buffer.
    ///
    /// The **only** place logical region coordinates become device pixels for a crop. The
    /// screenshot buffer is in device pixels; the region came from an overlay laid out in
    /// logical points. Getting this wrong silently crops the wrong area on Retina.
    public static func cropPixelRect(for region: LogicalRect, in space: CoordinateSpace) -> CGRect {
        let deviceOrigin = space.devicePoint(for: LogicalPoint(x: region.minX, y: region.minY))
        let deviceSize = space.deviceSize(for: region.size)
        return CGRect(x: CGFloat(deviceOrigin.x),
                      y: CGFloat(deviceOrigin.y),
                      width: CGFloat(deviceSize.width),
                      height: CGFloat(deviceSize.height))
    }

    /// The crop rect as a `CGImage`-safe rect: integer origin and size, inside bounds.
    ///
    /// `CGImage.cropping(to:)` requires integer bounds and throws if the rect escapes the
    /// image, so this clamps rather than trusting the caller.
    public static func safeCropRect(for region: LogicalRect,
                                    in space: CoordinateSpace,
                                    imageSize: DeviceSize) -> CGRect {
        let raw = cropPixelRect(for: region, in: space)
        let x = max(0, min(Int(raw.origin.x), imageSize.width))
        let y = max(0, min(Int(raw.origin.y), imageSize.height))
        let maxWidth = imageSize.width - x
        let maxHeight = imageSize.height - y
        let width = max(1, min(Int(raw.width), maxWidth))
        let height = max(1, min(Int(raw.height), maxHeight))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
