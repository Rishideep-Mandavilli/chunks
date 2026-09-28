import CoreGraphics
import ChunksTestHarness
@testable import ChunksKit

/// Tests for the geometry that turns the model's answer back into a screen position.
///
/// This is the step with no visual feedback when it is wrong: a bad mapping does not
/// crash, it just parks the cursor somewhere else and says nothing. So it is tested hard.
public enum ScreenCaptureTests {

    static let mainDisplay = DisplayInfo(
        displayID: 1,
        frame: LogicalRect(x: 0, y: 0, width: 1710, height: 1107),
        backingScale: 2,
        isMain: true)

    /// A second display to the right, as macOS reports it: x offset positive, y zero.
    static let sideDisplay = DisplayInfo(
        displayID: 2,
        frame: LogicalRect(x: 1710, y: 0, width: 2560, height: 1440),
        backingScale: 2,
        isMain: false)

    /// A solid-colour image of a given pixel size.
    static func makeImage(width: Int, height: Int,
                          colour: CGColor = CGColor(gray: 0.4, alpha: 1)) -> CGImage {
        let context = CGContext(data: nil,
                                width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(colour)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    public static func register() {
        TestRunner.currentSuite = "ScreenCapture geometry"

        // MARK: Scale

        test("scale is measured from the image, not assumed from the display") {
            // 400 logical points captured as 800 pixels means 2x.
            let capture = ScreenCapture(image: makeImage(width: 800, height: 600),
                                        globalRect: LogicalRect(x: 0, y: 0, width: 400, height: 300))
            expectEqual(capture.measuredScale, 2.0)
        }

        // This is the robustness property that makes measuring worth it: if the OS ever
        // returns a smaller image than the rect implies, points stay correct.
        test("a downscaled capture still maps correctly") {
            let capture = ScreenCapture(image: makeImage(width: 400, height: 300),
                                        globalRect: LogicalRect(x: 0, y: 0, width: 400, height: 300))
            expectEqual(capture.measuredScale, 1.0)
            let p = capture.globalPoint(forImagePixelX: 100, 50)
            expectEqual(p, LogicalPoint(x: 100, y: 50), "scale 1x must be an identity mapping")
        }

        test("a 1.5x fractional-scale capture is handled") {
            let capture = ScreenCapture(image: makeImage(width: 600, height: 450),
                                        globalRect: LogicalRect(x: 0, y: 0, width: 400, height: 300))
            expectEqual(capture.measuredScale, 1.5)
            let p = capture.globalPoint(forImagePixelX: 150, 75)
            expect(abs(p.x - 100) < 0.001, "x should be 100, got \(p.x)")
            expect(abs(p.y - 50) < 0.001, "y should be 50, got \(p.y)")
        }

        // MARK: Image pixel -> global point

        test("the image origin maps to the capture rect's origin") {
            let capture = ScreenCapture(image: makeImage(width: 800, height: 600),
                                        globalRect: LogicalRect(x: 300, y: 200, width: 400, height: 300))
            let p = capture.globalPoint(forImagePixelX: 0, 0)
            expectEqual(p, LogicalPoint(x: 300, y: 200), "top-left of the crop must be the crop's top-left")
        }

        test("the far corner maps to the far corner") {
            let capture = ScreenCapture(image: makeImage(width: 800, height: 600),
                                        globalRect: LogicalRect(x: 300, y: 200, width: 400, height: 300))
            let p = capture.globalPoint(forImagePixelX: 800, 600)
            expectEqual(p, LogicalPoint(x: 700, y: 500))
        }

        test("the centre of a Retina crop maps to the centre of the region") {
            let capture = ScreenCapture(image: makeImage(width: 800, height: 600),
                                        globalRect: LogicalRect(x: 300, y: 200, width: 400, height: 300))
            let p = capture.globalPoint(forImagePixelX: 400, 300)
            expectEqual(p, LogicalPoint(x: 500, y: 350))
        }

        // The bug this guards: dropping the scale factor puts the cursor at half or double
        // the intended offset, which looks like the app "sort of works" and is unusable.
        test("dropping the Retina scale would put the point in the wrong place") {
            let capture = ScreenCapture(image: makeImage(width: 800, height: 600),
                                        globalRect: LogicalRect(x: 300, y: 200, width: 400, height: 300))
            let correct = capture.globalPoint(forImagePixelX: 400, 300)
            let naive = LogicalPoint(x: 300 + 400, y: 200 + 300)
            expect(correct != naive, "the scale factor must actually change the result")
            expectEqual(naive, LogicalPoint(x: 700, y: 500), "the naive answer is the far corner")
        }

        // MARK: Local point -> image pixel (annotation compositing)

        test("a display-local point maps into the crop's pixel space") {
            // Crop is global (300,200)-(700,500); on the main display that is local
            // (300,200)-(700,500) because the display frame starts at the origin.
            let capture = ScreenCapture(image: makeImage(width: 800, height: 600),
                                        globalRect: LogicalRect(x: 300, y: 200, width: 400, height: 300))
            let pixel = capture.imagePixel(forLocal: LogicalPoint(x: 500, y: 350), display: mainDisplay)
            expectEqual(pixel, LogicalPoint(x: 400, y: 300), "the centre should be the image centre")
        }

        test("a point on the display's origin maps to a negative image pixel when outside the crop") {
            let capture = ScreenCapture(image: makeImage(width: 800, height: 600),
                                        globalRect: LogicalRect(x: 300, y: 200, width: 400, height: 300))
            let pixel = capture.imagePixel(forLocal: LogicalPoint(x: 0, y: 0), display: mainDisplay)
            expect(pixel.x < 0 && pixel.y < 0,
                   "a point left of the crop should fall outside the image, got \(pixel)")
        }

        // Round trip: a drawn mark lands on the pixel it came from, and the model's answer
        // about that pixel lands back on the same screen position.
        test("local -> image pixel -> global round trips exactly") {
            let rect = LogicalRect(x: 120, y: 90, width: 500, height: 400)
            let capture = ScreenCapture(image: makeImage(width: 1000, height: 800), globalRect: rect)
            for local in [LogicalPoint(x: 120, y: 90),
                          LogicalPoint(x: 620, y: 490),
                          LogicalPoint(x: 371, y: 288)] {
                let pixel = capture.imagePixel(forLocal: local, display: mainDisplay)
                let back = capture.globalPoint(forImagePixelX: pixel.x, pixel.y)
                expect(abs(back.x - local.x) < 0.001, "x round trip: \(local) -> \(pixel) -> \(back)")
                expect(abs(back.y - local.y) < 0.001, "y round trip: \(local) -> \(pixel) -> \(back)")
            }
        }

        // MARK: Second display

        test("a crop on a secondary display maps to the secondary display's coordinates") {
            // Side display frame is (1710,0)-(4270,1440). A crop at its top-left.
            let capture = ScreenCapture(image: makeImage(width: 800, height: 600),
                                        globalRect: LogicalRect(x: 1710, y: 0, width: 400, height: 300))
            let p = capture.globalPoint(forImagePixelX: 400, 300)
            expectEqual(p, LogicalPoint(x: 1910, y: 150))
        }

        test("local coordinates on a secondary display resolve against its own origin") {
            let capture = ScreenCapture(image: makeImage(width: 800, height: 600),
                                        globalRect: LogicalRect(x: 1710, y: 0, width: 400, height: 300))
            // Local (200,150) on the side display is global (1910,150) is image (400,300).
            let pixel = capture.imagePixel(forLocal: LogicalPoint(x: 200, y: 150), display: sideDisplay)
            expectEqual(pixel, LogicalPoint(x: 400, y: 300))
        }

        // MARK: Compositing

        test("compositing with no marks returns the original image") {
            let image = makeImage(width: 400, height: 300)
            let capture = ScreenCapture(image: image, globalRect: LogicalRect(x: 0, y: 0, width: 200, height: 150))
            let result = capture.composited(with: [], display: mainDisplay)
            expectEqual(result.width, 400)
            expectEqual(result.height, 300)
        }

        // The failure this prevents: a crop with no visible highlight is an ordinary crop,
        // and the model has no idea which of the forty buttons was meant.
        test("compositing marks changes the image but preserves its size") {
            let rect = LogicalRect(x: 200, y: 200, width: 300, height: 200)
            let plain = ScreenCapture(image: makeImage(width: 600, height: 400), globalRect: rect)
            let marked = plain.composited(with: [
                .ellipse(center: LogicalPoint(x: 350, y: 300), radiusX: 40, radiusY: 20),
            ], display: mainDisplay)
            expectEqual(marked.width, 600, "compositing must not resize")
            expectEqual(marked.height, 400)

            let plainPixels = pixelBytes(plain.image)
            let markedPixels = pixelBytes(marked)
            expect(plainPixels != markedPixels, "the mark was not actually drawn")
        }

        test("compositing each mark type produces a drawable image") {
            let rect = LogicalRect(x: 0, y: 0, width: 400, height: 300)
            let shapes: [AnnotationShape] = [
                .stroke([LogicalPoint(x: 20, y: 20), LogicalPoint(x: 300, y: 200)]),
                .ellipse(center: LogicalPoint(x: 200, y: 150), radiusX: 30, radiusY: 30),
                .rect(LogicalRect(x: 50, y: 50, width: 100, height: 60)),
                .arrow(from: LogicalPoint(x: 10, y: 280), to: LogicalPoint(x: 390, y: 280)),
            ]
            for shape in shapes {
                let capture = ScreenCapture(image: makeImage(width: 800, height: 600), globalRect: rect)
                let result = capture.composited(with: [shape], display: mainDisplay)
                expectEqual(result.width, 800, "\(shape) changed the width")
                expect(pixelBytes(result) != pixelBytes(capture.image), "\(shape) drew nothing")
            }
        }

        test("an empty stroke does not crash compositing") {
            let capture = ScreenCapture(image: makeImage(width: 100, height: 100),
                                        globalRect: LogicalRect(x: 0, y: 0, width: 100, height: 100))
            let result = capture.composited(with: [.stroke([])], display: mainDisplay)
            expectEqual(result.width, 100)
        }
    }

    /// Raw bytes of an image, for "did anything actually get drawn" assertions.
    static func pixelBytes(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes,
                                width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }
}
