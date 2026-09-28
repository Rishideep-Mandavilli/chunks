import CoreGraphics
import Foundation

// MARK: - Geometry primitives

/// A point in macOS **logical** space (the space AX APIs report and that views lay out in).
/// On a Retina display this is the "point" value, not the "pixel" value.
public struct LogicalPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// A point in **device** space — what a screenshot buffer and CGEvent pixel coordinates use.
public struct DevicePoint: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public struct LogicalSize: Hashable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct DeviceSize: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public struct LogicalRect: Hashable, Sendable {
    public var origin: LogicalPoint
    public var size: LogicalSize
    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = LogicalPoint(x: x, y: y)
        size = LogicalSize(width: width, height: height)
    }
    public var width: Double { size.width }
    public var height: Double { size.height }
    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + size.width / 2 }
    public var midY: Double { origin.y + size.height / 2 }
    public var isEmpty: Bool { size.width <= 0 || size.height <= 0 }
}

// MARK: - The coordinate authority

/// **The only type permitted to convert between logical and device coordinates.**
///
/// This exists because mixing the two is the single most common bug in macOS screen
/// tooling. Screenshots arrive in device pixels (e.g. 3420x2214). The Accessibility API
/// reports logical points (e.g. 1710x1107). `NSPanel` frames are logical. CoreGraphics
/// event *pixel* coordinates are device pixels. Feed an AX `frame` straight into a
/// pixel-based click API and everything lands at double the intended offset on Retina.
///
/// Rule for the codebase: every layer stores `LogicalPoint`. Conversion happens exactly
/// once, here, at the boundary.
public struct CoordinateSpace: Sendable, Equatable {

    /// Backing scale factor: 1.0 on non-Retina, 2.0 on Retina, 3.0 on some iMacs.
    public let scale: Double

    /// Frame of the target display in global logical coordinates.
    public let displayFrame: LogicalRect

    public init(scale: Double, displayFrame: LogicalRect) {
        precondition(scale > 0, "backingScaleFactor must be positive")
        self.scale = scale
        self.displayFrame = displayFrame
    }

    /// Build from a display's logical frame plus its backing scale.
    public init(scale: Double, displayFrame: CGRect) {
        self.init(scale: scale,
                  displayFrame: LogicalRect(x: displayFrame.origin.x,
                                            y: displayFrame.origin.y,
                                            width: displayFrame.width,
                                            height: displayFrame.height))
    }

    // MARK: Logical -> Device

    public func devicePoint(for p: LogicalPoint) -> DevicePoint {
        DevicePoint(x: Int((p.x * scale).rounded()),
                    y: Int((p.y * scale).rounded()))
    }

    public func deviceSize(for s: LogicalSize) -> DeviceSize {
        DeviceSize(width: Int((s.width * scale).rounded()),
                   height: Int((s.height * scale).rounded()))
    }

    // MARK: Device -> Logical

    public func logicalPoint(for p: DevicePoint) -> LogicalPoint {
        LogicalPoint(x: Double(p.x) / scale, y: Double(p.y) / scale)
    }

    public func logicalSize(for s: DeviceSize) -> LogicalSize {
        LogicalSize(width: Double(s.width) / scale, height: Double(s.height) / scale)
    }

    // MARK: Space conversion (global <-> display-local)

    /// Global logical coordinates -> coordinates local to this display's top-left.
    public func localPoint(for p: LogicalPoint) -> LogicalPoint {
        LogicalPoint(x: p.x - displayFrame.minX, y: p.y - displayFrame.minY)
    }

    /// Display-local logical coordinates -> global logical coordinates.
    public func globalPoint(for p: LogicalPoint) -> LogicalPoint {
        LogicalPoint(x: p.x + displayFrame.minX, y: p.y + displayFrame.minY)
    }

    /// A rect given in **display-local** logical coordinates, expressed globally.
    /// This is the one used for cropping screenshots: the crop rectangle you read off
    /// an on-screen overlay is display-local, but the screenshot buffer is the whole display.
    public func globalRect(fromLocal rect: LogicalRect) -> LogicalRect {
        LogicalRect(x: rect.minX + displayFrame.minX,
                    y: rect.minY + displayFrame.minY,
                    width: rect.width,
                    height: rect.height)
    }

    /// Inverse of `globalRect(fromLocal:)`.
    public func localRect(fromGlobal rect: LogicalRect) -> LogicalRect {
        LogicalRect(x: rect.minX - displayFrame.minX,
                    y: rect.minY - displayFrame.minY,
                    width: rect.width,
                    height: rect.height)
    }

    // MARK: Bounds

    /// Size of a screenshot buffer captured from this display.
    public var deviceCaptureSize: DeviceSize {
        deviceSize(for: displayFrame.size)
    }

    /// Clamp a logical rect into this display's bounds.
    ///
    /// Clamps **both** edges, not just the origin. Origin-only clamping is wrong in the
    /// common case: a rect at `(-500, -500, 100, 100)` is entirely off-screen and must
    /// collapse to zero width, but moving only the origin to `(0, 0)` leaves a 100x100
    /// box of content the user never asked to see.
    public func clampedToDisplay(_ rect: LogicalRect) -> LogicalRect {
        func clampEdge(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
            min(max(v, lo), hi)
        }
        let lo = displayFrame.minX, hi = displayFrame.maxX
        let top = displayFrame.minY, bottom = displayFrame.maxY

        let x0 = clampEdge(rect.minX, lo, hi)
        let x1 = clampEdge(rect.maxX, lo, hi)
        let y0 = clampEdge(rect.minY, top, bottom)
        let y1 = clampEdge(rect.maxY, top, bottom)

        return LogicalRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    public func contains(_ p: LogicalPoint) -> Bool {
        p.x >= displayFrame.minX && p.x < displayFrame.maxX
            && p.y >= displayFrame.minY && p.y < displayFrame.maxY
    }
}
