import CoreGraphics
import ChunksTestHarness
@testable import ChunksKit

public enum RegionResolverTests {

    /// A 1440x932 logical Retina panel — the real machine's display.
    static let display = LogicalSize(width: 1440, height: 932)
    static let space2x = CoordinateSpace(scale: 2, displayFrame: LogicalRect(x: 0, y: 0, width: 1440, height: 932))

    public static func register() {
        TestRunner.currentSuite = "RegionResolver"

        // MARK: Bounding boxes

        test("a freehand stroke's box covers all its points") {
            let box = AnnotationShape.stroke([LogicalPoint(x: 10, y: 20), LogicalPoint(x: 100, y: 60),
                                              LogicalPoint(x: 50, y: 5)]).boundingBox
            expectEqual(box, LogicalRect(x: 10, y: 5, width: 90, height: 55))
        }

        test("an ellipse's box includes its stroke width") {
            let box = AnnotationShape.ellipse(center: LogicalPoint(x: 100, y: 100), radiusX: 40, radiusY: 20).boundingBox
            let pad = AnnotationShape.strokeWidth
            expectEqual(box.minX, 100 - 40 - pad)
            expectEqual(box.width, (40 + pad) * 2)
            expectEqual(box.height, (20 + pad) * 2)
        }

        test("an arrow's box spans tail to head regardless of direction") {
            let forward = AnnotationShape.arrow(from: LogicalPoint(x: 10, y: 10), to: LogicalPoint(x: 100, y: 100)).boundingBox
            let backward = AnnotationShape.arrow(from: LogicalPoint(x: 100, y: 100), to: LogicalPoint(x: 10, y: 10)).boundingBox
            expectEqual(forward, backward, "arrow direction should not change its box")
        }

        test("an empty stroke has an empty box rather than crashing") {
            let box = AnnotationShape.stroke([]).boundingBox
            expectEqual(box.width, 0)
            expectEqual(box.height, 0)
        }

        // MARK: Session

        test("a session's box is the union of its marks") {
            let s = AnnotationSession(shapes: [
                .rect(LogicalRect(x: 10, y: 10, width: 50, height: 50)),
                .rect(LogicalRect(x: 200, y: 300, width: 50, height: 50)),
            ])
            guard let box = s.boundingBox else { return expect(false, "expected a box") }
            expectEqual(box.minX, 10 - AnnotationShape.strokeWidth)
            expectEqual(box.maxX, 250 + AnnotationShape.strokeWidth)
            expectEqual(box.maxY, 350 + AnnotationShape.strokeWidth)
        }

        test("undo removes the most recent mark and clear removes all") {
            var s = AnnotationSession()
            expect(s.isEmpty)
            s.add(.rect(LogicalRect(x: 0, y: 0, width: 10, height: 10)))
            s.add(.ellipse(center: LogicalPoint(x: 50, y: 50), radiusX: 5, radiusY: 5))
            expectEqual(s.shapes.count, 2)
            s.undo()
            expectEqual(s.shapes.count, 1)
            s.clear()
            expect(s.isEmpty)
            expect(s.boundingBox == nil, "an empty session has no box")
        }

        test("undo on an empty session is harmless") {
            var s = AnnotationSession()
            s.undo(); s.undo()
            expect(s.isEmpty)
        }

        test("the model-facing description is pluralised and intent-neutral") {
            let s = AnnotationSession(shapes: [
                .ellipse(center: LogicalPoint(x: 5, y: 5), radiusX: 5, radiusY: 5),
                .stroke([LogicalPoint(x: 1, y: 1), LogicalPoint(x: 9, y: 9)]),
            ])
            let d = s.descriptionForModel
            expect(d.contains("circled"), d)
            expect(d.contains("drew over"), d)
            expect(d.contains("1 region circled"), "singular form wrong: \(d)")

            let two = AnnotationSession(shapes: [
                .rect(LogicalRect(x: 0, y: 0, width: 1, height: 1)),
                .rect(LogicalRect(x: 5, y: 5, width: 1, height: 1)),
            ])
            expect(two.descriptionForModel.contains("2 regions boxed"), two.descriptionForModel)
        }

        // MARK: Resolution

        test("no marks means the whole display") {
            let r = RegionResolver.resolve(shapes: [], displaySize: display)
            expectEqual(r, LogicalRect(x: 0, y: 0, width: 1440, height: 932))
            expectEqual(RegionResolver.wholeScreen(displaySize: display), r)
        }

        test("a mark is padded with surrounding context") {
            let mark = AnnotationShape.ellipse(center: LogicalPoint(x: 700, y: 400), radiusX: 40, radiusY: 40)
            let r = RegionResolver.resolve(shapes: [mark], displaySize: display)
            // Wider than the circle itself, by the margin on each side.
            expect(r.width > 80 + 40, "no context padding: width \(r.width)")
            expect(r.height > 80 + 40, "no context padding: height \(r.height)")
            // Still centred on the mark.
            expect(abs(r.midX - 700) < 1, "crop drifted horizontally: midX \(r.midX)")
            expect(abs(r.midY - 400) < 1, "crop drifted vertically: midY \(r.midY)")
        }

        test("a tiny accidental dot still yields a usable crop") {
            let dot = AnnotationShape.stroke([LogicalPoint(x: 500, y: 500)])
            let r = RegionResolver.resolve(shapes: [dot], displaySize: display)
            expect(r.width >= RegionResolver.minimumSize.width, "too narrow: \(r.width)")
            expect(r.height >= RegionResolver.minimumSize.height, "too short: \(r.height)")
        }

        test("a crop never escapes the display") {
            // Marks hugging each edge, including negative-ish and overhanging coordinates.
            let marks: [AnnotationShape] = [
                .ellipse(center: LogicalPoint(x: 2, y: 2), radiusX: 30, radiusY: 30),
                .ellipse(center: LogicalPoint(x: 1438, y: 930), radiusX: 30, radiusY: 30),
                .rect(LogicalRect(x: -40, y: -40, width: 60, height: 60)),
                .rect(LogicalRect(x: 1400, y: 900, width: 200, height: 200)),
            ]
            let r = RegionResolver.resolve(shapes: marks, displaySize: display)
            expect(r.minX >= 0, "crop starts left of the display: \(r.minX)")
            expect(r.minY >= 0, "crop starts above the display: \(r.minY)")
            expect(r.maxX <= 1440.001, "crop ends right of the display: \(r.maxX)")
            expect(r.maxY <= 932.001, "crop ends below the display: \(r.maxY)")
        }

        test("marks spread across the whole display produce the whole display") {
            let marks: [AnnotationShape] = [
                .ellipse(center: LogicalPoint(x: 30, y: 30), radiusX: 10, radiusY: 10),
                .ellipse(center: LogicalPoint(x: 1410, y: 900), radiusX: 10, radiusY: 10),
            ]
            let r = RegionResolver.resolve(shapes: marks, displaySize: display)
            expectEqual(r.width, 1440)
            expectEqual(r.height, 932)
        }
    }
}
