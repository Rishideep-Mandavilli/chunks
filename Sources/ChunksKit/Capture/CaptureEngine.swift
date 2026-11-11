import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A display, with everything needed to map between its coordinate spaces.
public struct DisplayInfo: Sendable, Equatable {
    public let displayID: CGDirectDisplayID

    /// Frame in **global logical coordinates**, using CoreGraphics' top-left origin
    /// (`CGDisplayBounds`), not AppKit's bottom-left origin (`NSScreen.frame`).
    ///
    /// This distinction is the single most common source of upside-down cursor positions
    /// in multi-macOS screen tooling. Everything in Chunks uses the CG convention; nothing
    /// mixes the two.
    public let frame: LogicalRect

    public let backingScale: Double
    public let isMain: Bool

    public var space: CoordinateSpace {
        CoordinateSpace(scale: backingScale, displayFrame: frame)
    }

    public var size: LogicalSize { frame.size }

    public init(displayID: CGDirectDisplayID, frame: LogicalRect, backingScale: Double, isMain: Bool) {
        self.displayID = displayID
        self.frame = frame
        self.backingScale = backingScale
        self.isMain = isMain
    }
}

/// A captured image, bundled with the region it covers.
///
/// Carrying the region alongside the pixels is not bookkeeping — it is what makes the
/// model's `[POINT:x,y]` resolvable to a real screen position. An image on its own has
/// lost the information needed to place a click.
public struct ScreenCapture: Sendable {

    public let image: CGImage
    public let globalRect: LogicalRect

    public var pixelSize: DeviceSize {
        DeviceSize(width: image.width, height: image.height)
    }

    /// Device pixels per logical point, **measured** from the returned image rather than
    /// read off the display.
    ///
    /// Measuring rather than assuming means a mismatch is impossible to paper over: if
    /// `SCScreenshotManager` ever returned a scaled-down image (which it does when the
    /// rect is large and it clamps), point placement stays correct anyway.
    public var measuredScale: Double {
        guard globalRect.width > 0 else { return 1 }
        return Double(image.width) / globalRect.width
    }

    public init(image: CGImage, globalRect: LogicalRect) {
        self.image = image
        self.globalRect = globalRect
    }

    /// Pixel coordinate **within this image** -> global logical point.
    ///
    /// This is the resolution step for `[POINT:x,y]`. The model is shown only this crop
    /// and is asked for coordinates in the image's own pixel space, so the mapping is a
    /// scale and an offset — no reasoning about which display is involved.
    public func globalPoint(forImagePixelX pixelX: Double, _ pixelY: Double) -> LogicalPoint {
        let scale = measuredScale
        return LogicalPoint(x: globalRect.minX + pixelX / scale,
                            y: globalRect.minY + pixelY / scale)
    }

    /// PNG bytes plus the geometry needed to interpret the model's answer.
    public func png() -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Annotation compositing

    /// A point the user drew, in **display-local logical coordinates** -> a pixel
    /// coordinate inside this image.
    ///
    /// The mapping is `imagePixel = (local - cropLocalOrigin) * scale`. It matters that
    /// this is measured from the actual image rather than from the display's declared
    /// scale: `SCScreenshotManager` is free to return a smaller image than the rect
    /// implies, and using the display's scale then draws every mark in the wrong place.
    public func imagePixel(forLocal point: LogicalPoint, display: DisplayInfo) -> LogicalPoint {
        let cropLocal = display.space.localRect(fromGlobal: globalRect)
        let scale = measuredScale
        return LogicalPoint(x: (point.x - cropLocal.minX) * scale,
                            y: (point.y - cropLocal.minY) * scale)
    }

    /// The user's marks burned into the image, so the model sees the circle rather than
    /// only being told about it.
    ///
    /// This is the whole point of circle-to-explain: the model reads the highlight the way
    /// a person would. A crop alone loses the signal — a 400x300 crop of a browser looks
    /// like a browser, and the model has no idea which button was meant.
    ///
    /// Returns the original image when compositing is impossible, because an explanation
    /// without the highlight is still useful and a failed turn is not.
    public func composited(with shapes: [AnnotationShape], display: DisplayInfo) -> CGImage {
        guard !shapes.isEmpty, image.width > 0, image.height > 0 else { return image }

        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Stroke width scales with the image so a mark is the same visual weight whether
        // it was drawn on a 400x300 crop or a 3000x2000 full screen.
        let lineWidth = max(2.0, AnnotationShape.strokeWidth * measuredScale)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(AnnotationShape.overlayStrokeColor)
        context.setFillColor(AnnotationShape.overlayStrokeColor)

        func px(_ p: LogicalPoint) -> CGPoint {
            let q = imagePixel(forLocal: p, display: display)
            return CGPoint(x: q.x, y: q.y)
        }

        for shape in shapes {
            switch shape {
            case .stroke(let points):
                guard let first = points.first else { continue }
                context.beginPath()
                context.move(to: px(first))
                for p in points.dropFirst() { context.addLine(to: px(p)) }
                context.strokePath()

            case .ellipse(let center, let radiusX, let radiusY):
                let scale = measuredScale
                let rect = CGRect(x: (center.x - radiusX) * scale - cropX(display),
                                  y: (center.y - radiusY) * scale - cropY(display),
                                  width: radiusX * 2 * scale,
                                  height: radiusY * 2 * scale)
                context.strokeEllipse(in: rect)

            case .rect(let r):
                let topLeft = px(LogicalPoint(x: r.minX, y: r.minY))
                let rect = CGRect(x: topLeft.x, y: topLeft.y,
                                  width: r.width * measuredScale,
                                  height: r.height * measuredScale)
                context.stroke(rect)

            case .arrow(let from, let to):
                drawArrow(from: px(from), to: px(to), lineWidth: lineWidth, context: context)

            case .line(let from, let to):
                context.beginPath()
                context.move(to: px(from))
                context.addLine(to: px(to))
                context.strokePath()

            case .pin(let point):
                let c = px(point)
                let dot = AnnotationShape.pinDotRadius * measuredScale
                context.fillEllipse(in: CGRect(x: c.x - dot, y: c.y - dot,
                                               width: dot * 2, height: dot * 2))
                let ring = (AnnotationShape.pinDotRadius + AnnotationShape.pinRingGap) * measuredScale
                context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                context.setLineWidth(AnnotationShape.pinRingWidth * measuredScale)
                context.strokeEllipse(in: CGRect(x: c.x - ring, y: c.y - ring,
                                                 width: ring * 2, height: ring * 2))
                context.setStrokeColor(AnnotationShape.overlayStrokeColor)
                context.setLineWidth(lineWidth)

            case .highlight(let r):
                let topLeft = px(LogicalPoint(x: r.minX, y: r.minY))
                context.setFillColor(AnnotationShape.overlayStrokeColor.copy(alpha: 0.22)
                                     ?? AnnotationShape.overlayStrokeColor)
                context.fill(CGRect(x: topLeft.x, y: topLeft.y,
                                    width: r.width * measuredScale, height: r.height * measuredScale))
                context.setFillColor(AnnotationShape.overlayStrokeColor)

            case .underline(let r):
                let a = px(LogicalPoint(x: r.minX, y: r.maxY))
                let b = px(LogicalPoint(x: r.maxX, y: r.maxY))
                context.beginPath()
                context.move(to: a)
                context.addLine(to: b)
                context.strokePath()

            case .text:
                // Written words live on the passive ink layer for the user; they are not burned
                // into the crop the model reads (the model already has the unmarked picture).
                continue
            }
        }

        return context.makeImage() ?? image
    }

    private func cropX(_ display: DisplayInfo) -> Double {
        display.space.localRect(fromGlobal: globalRect).minX * measuredScale
    }

    private func cropY(_ display: DisplayInfo) -> Double {
        display.space.localRect(fromGlobal: globalRect).minY * measuredScale
    }

    private func drawArrow(from: CGPoint, to: CGPoint, lineWidth: CGFloat, context: CGContext) {
        let headLength = max(8, lineWidth * 3.5)
        let angle = atan2(to.y - from.y, to.x - from.x)

        context.beginPath()
        context.move(to: from)
        context.addLine(to: to)
        context.strokePath()

        context.beginPath()
        context.move(to: to)
        context.addLine(to: CGPoint(x: to.x - headLength * cos(angle - .pi / 7),
                                    y: to.y - headLength * sin(angle - .pi / 7)))
        context.addLine(to: CGPoint(x: to.x - headLength * cos(angle + .pi / 7),
                                    y: to.y - headLength * sin(angle + .pi / 7)))
        context.closePath()
        context.fillPath()
    }
}

/// Captures the user's screen.
///
/// Uses `SCScreenshotManager.captureImage(in:)` — a one-shot, display-agnostic API that
/// takes a rect in **points** and returns the pixels. Two deliberate choices:
///
/// 1. **Not `SCStream`.** Chunks is not a recorder. A stream means a live capture pipeline
///    to start, keep alive between turns, and tear down — and it delivers sample buffers
///    that still need converting to `CGImage` by hand.
/// 2. **Not `SCShareableContent`.** macOS 26 deprecated it, and the replacement,
///    `SCContentSharingPicker`, requires the user to click through a system dialog. The
///    picker would fire on every single question, which defeats the point of a hotkey.
///
/// Requires Screen Recording permission. macOS only honours a newly granted permission
/// after relaunch, so the UI must say "restart Chunks" rather than implying it works now.
public actor CaptureEngine {

    public enum CaptureError: Error, CustomStringConvertible {
        case notAuthorised
        case noDisplays
        case captureFailed(String)
        case emptyImage

        public var description: String {
            switch self {
            case .notAuthorised:
                return "Chunks needs Screen Recording access to see your screen. Grant it in "
                     + "System Settings → Privacy & Security → Screen Recording, then quit "
                     + "and reopen Chunks — macOS only applies the permission after a relaunch."
            case .noDisplays:
                return "No display found."
            case .captureFailed(let detail):
                return "Screen capture failed: \(detail)"
            case .emptyImage:
                return "Captured an empty frame."
            }
        }
    }

    public init() {}

    // MARK: - Permission

    public static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Trigger the system prompt. The grant itself only takes effect after relaunch.
    @discardableResult
    public static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Displays

    /// Every connected display, main first.
    public static func displays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        let mainID = CGMainDisplayID()

        // The backing scale comes from `NSScreen.backingScaleFactor`, keyed by screen
        // number, and **not** from `CGDisplayPixelsWide`.
        //
        // Measured on this machine (macOS 27, 1710x1107 display that captures at
        // 3420x2214): `CGDisplayPixelsWide` returns 1710 — the *point* count, not the
        // pixel count. Deriving `pixelsWide / bounds.width` therefore yields exactly 1.0
        // on a Retina display, which is the worst possible answer: it is not an error, it
        // is a plausible number, and every click lands at half the intended offset with
        // nothing logged. `NSScreen.backingScaleFactor` returns the correct 2.0.
        var scales: [CGDirectDisplayID: Double] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            scales[CGDirectDisplayID(number.uint32Value)] = screen.backingScaleFactor
        }

        let infos: [DisplayInfo] = ids.prefix(Int(count)).compactMap { id in
            let bounds = CGDisplayBounds(id)
            guard bounds.width > 0, bounds.height > 0 else { return nil }

            return DisplayInfo(
                displayID: id,
                frame: LogicalRect(x: bounds.origin.x, y: bounds.origin.y,
                                   width: bounds.width, height: bounds.height),
                backingScale: max(1, scales[id] ?? 1),
                isMain: id == mainID)
        }
        return infos.sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            return lhs.displayID < rhs.displayID
        }
    }

    public static func mainDisplay() -> DisplayInfo? {
        displays().first { $0.isMain } ?? displays().first
    }

    /// A synthetic display used to place the answer panel when enumeration has failed.
    ///
    /// The panel has to have somewhere to appear even when the app cannot work, because
    /// that is exactly when the user most needs to be told what is wrong. Sized to a
    /// typical built-in display so the card lands in the middle of the screen rather than
    /// at some absurd coordinate.
    public static let fallbackDisplay = DisplayInfo(
        displayID: 0,
        frame: LogicalRect(x: 0, y: 0, width: 1440, height: 900),
        backingScale: 2,
        isMain: true)

    /// Resolve the model's 1-based `screenN` to a real display.
    public static func display(index oneBased: Int) -> DisplayInfo? {
        let all = displays()
        guard oneBased >= 1, oneBased <= all.count else { return nil }
        return all[oneBased - 1]
    }

    // MARK: - Capture

    /// Capture the given region, in **global logical points**.
    public func capture(globalRect rect: LogicalRect) async throws -> ScreenCapture {
        guard Self.hasScreenRecordingPermission() else { throw CaptureError.notAuthorised }

        let clamped = Self.sanitise(rect)
        guard clamped.width >= 1, clamped.height >= 1 else { throw CaptureError.emptyImage }

        let cgRect = CGRect(x: clamped.minX, y: clamped.minY,
                            width: clamped.width, height: clamped.height)

        let image: CGImage = try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: cgRect) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? CaptureError.captureFailed("no image returned"))
                }
            }
        }

        return ScreenCapture(image: image, globalRect: clamped)
    }

    /// Capture a whole display.
    public func capture(display: DisplayInfo) async throws -> ScreenCapture {
        try await capture(globalRect: display.frame)
    }

    /// Capture a region given in **display-local** logical points — the coordinate space
    /// an annotation overlay drawn over that display reports in.
    public func capture(display: DisplayInfo, localRegion: LogicalRect) async throws -> ScreenCapture {
        try await capture(globalRect: display.space.globalRect(fromLocal: localRegion))
    }

    /// Capture whatever the user's question is about, resolving the region from the marks
    /// they drew.
    ///
    /// No marks means the whole display, which is what makes "hold the hotkey and ask"
    /// work with no drawing at all.
    public func capture(display: DisplayInfo, shapes: [AnnotationShape]) async throws -> ScreenCapture {
        let local = RegionResolver.resolve(shapes: shapes, displaySize: display.size)
        return try await capture(display: display, localRegion: local)
    }

    /// Round a rect to something `SCScreenshotManager` will accept.
    ///
    /// It rejects empty and non-positive rects, and fractional origins can land between
    /// pixels on a fractional-scale display. Clamping here means a bad region produces a
    /// slightly-wrong crop rather than a thrown error mid-turn.
    private static func sanitise(_ rect: LogicalRect) -> LogicalRect {
        LogicalRect(x: rect.minX.rounded(),
                    y: rect.minY.rounded(),
                    width: max(1, rect.width.rounded()),
                    height: max(1, rect.height.rounded()))
    }
}
