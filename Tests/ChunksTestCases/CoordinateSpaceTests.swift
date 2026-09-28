import CoreGraphics
import ChunksTestHarness
@testable import ChunksKit

/// These tests exist to catch one specific class of bug: mixing logical points with
/// device pixels. It is the most common defect in macOS screen tooling and it is silent —
/// a click lands "near" the target but not on it, so nothing errors, the feature just
/// quietly doesn't work at 2x.
public enum CoordinateSpaceTests {

    // MARK: Fixtures

    /// Non-Retina: logical and device spaces are identical.
    static let space1x = CoordinateSpace(scale: 1, displayFrame: LogicalRect(x: 0, y: 0, width: 1920, height: 1080))
    /// Retina laptop display, origin at the global top-left.
    static let space2x = CoordinateSpace(scale: 2, displayFrame: LogicalRect(x: 0, y: 0, width: 1710, height: 1110))
    /// Retina with a non-zero origin — a second monitor to the left/up of the main one.
    static let space2xOffset = CoordinateSpace(scale: 2, displayFrame: LogicalRect(x: -1440, y: -200, width: 1440, height: 900))
    /// 3x, which still exists on some iMacs and is easy to forget.
    static let space3x = CoordinateSpace(scale: 3, displayFrame: LogicalRect(x: 0, y: 0, width: 1728, height: 1117))

    public static func register() {
        TestRunner.currentSuite = "CoordinateSpace"

        test("logical -> device -> logical is lossless at 1x") {
            for p in [LogicalPoint(x: 0, y: 0), LogicalPoint(x: 960, y: 540), LogicalPoint(x: 1919, y: 1079)] {
                expectEqual(space1x.logicalPoint(for: space1x.devicePoint(for: p)), p)
            }
        }

        test("logical -> device -> logical is lossless at 2x") {
            for p in [LogicalPoint(x: 0, y: 0), LogicalPoint(x: 855, y: 555), LogicalPoint(x: 1709, y: 1109)] {
                expectEqual(space2x.logicalPoint(for: space2x.devicePoint(for: p)), p)
            }
        }

        test("logical -> device -> logical is lossless at 3x") {
            for p in [LogicalPoint(x: 0, y: 0), LogicalPoint(x: 864, y: 558), LogicalPoint(x: 1727, y: 1116)] {
                expectEqual(space3x.logicalPoint(for: space3x.devicePoint(for: p)), p)
            }
        }

        test("the bug this type exists to prevent: coords differ at 2x") {
            let logical = LogicalPoint(x: 100, y: 200)
            let device = space2x.devicePoint(for: logical)
            expectEqual(device, DevicePoint(x: 200, y: 400))
            // An implementation that skipped conversion would produce this wrong answer.
            expect(LogicalPoint(x: Double(device.x), y: Double(device.y)) != logical,
                   "logical and device coords were equal — conversion is not happening")
        }

        test("capture buffer size matches the display at each scale") {
            expectEqual(space1x.deviceCaptureSize, DeviceSize(width: 1920, height: 1080))
            expectEqual(space2x.deviceCaptureSize, DeviceSize(width: 3420, height: 2220))
            expectEqual(space3x.deviceCaptureSize, DeviceSize(width: 5184, height: 3351))
        }

        test("a 2880x1864 Retina panel captures at native resolution") {
            let s = CoordinateSpace(scale: 2, displayFrame: LogicalRect(x: 0, y: 0, width: 1440, height: 932))
            expectEqual(s.deviceCaptureSize, DeviceSize(width: 2880, height: 1864))
        }

        test("a secondary display's top-left has negative global coordinates") {
            let localTopLeft = LogicalPoint(x: 0, y: 0)
            let global = space2xOffset.globalPoint(for: localTopLeft)
            expectEqual(global, LogicalPoint(x: -1440, y: -200))
            expectEqual(space2xOffset.localPoint(for: global), localTopLeft)
        }

        test("a box drawn on-screen maps to the right crop rect in the screenshot buffer") {
            let drawn = LogicalRect(x: 50, y: 60, width: 200, height: 100)
            let global = space2xOffset.globalRect(fromLocal: drawn)
            expectEqual(global, LogicalRect(x: -1390, y: -140, width: 200, height: 100))
            expectEqual(space2xOffset.localRect(fromGlobal: global), drawn)
        }

        test("out-of-bounds rects clamp; fully-outside collapses to zero") {
            let off = LogicalRect(x: -500, y: -500, width: 100, height: 100)
            expectEqual(space1x.clampedToDisplay(off), LogicalRect(x: 0, y: 0, width: 0, height: 0))

            let over = LogicalRect(x: 1800, y: 1000, width: 500, height: 500)
            expectEqual(space1x.clampedToDisplay(over), LogicalRect(x: 1800, y: 1000, width: 120, height: 80))
        }

        test("a rect fully inside the display is unchanged") {
            let inside = LogicalRect(x: 100, y: 100, width: 50, height: 50)
            expectEqual(space1x.clampedToDisplay(inside), inside)
        }

        test("containment is half-open, so max edges are excluded") {
            expect(space1x.contains(LogicalPoint(x: 0, y: 0)))
            expect(space1x.contains(LogicalPoint(x: 1919.9, y: 1079.9)))
            expect(!space1x.contains(LogicalPoint(x: 1920, y: 0)), "max X edge should be excluded")
            expect(!space1x.contains(LogicalPoint(x: 0, y: 1080)), "max Y edge should be excluded")
        }

        test("construction from CGRect matches construction from LogicalRect") {
            let a = CoordinateSpace(scale: 2, displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 932))
            let b = CoordinateSpace(scale: 2, displayFrame: LogicalRect(x: 0, y: 0, width: 1440, height: 932))
            expect(a == b)
        }
    }
}
