import CoreGraphics
import ChunksTestHarness
@testable import ChunksKit

/// Tests for display enumeration against the **real** displays attached to this machine.
///
/// These are the tests that caught the worst bug in the project so far. `CGDisplayPixelsWide`
/// sounds like it returns a pixel count. On this machine it returns 1710 for a display that
/// is 1710 points wide and captures at 3420 pixels — it is reporting *points*, not pixels.
/// Deriving a backing scale from it yields exactly 1.0 on a Retina display, which is the
/// most dangerous possible failure: a plausible number, no error, and every click landing at
/// half the intended offset.
///
/// These tests therefore assert against the machine rather than against a mock, because the
/// whole point is that the mock would have agreed with the bug.
public enum DisplayEnumerationTests {

    public static func register() {
        TestRunner.currentSuite = "Display enumeration (live)"

        test("every display reports a backing scale of 1 or more") {
            // A loop over an empty array is a test that passes for free, and this one found
            // nothing to check on a sleeping display while still printing a tick.
            expect(!CaptureEngine.displays().isEmpty,
                   "no displays were enumerated — every loop below would pass with nothing in it")
            for display in CaptureEngine.displays() {
                expect(display.backingScale >= 1,
                       "display \(display.displayID) reported scale \(display.backingScale)")
                expect(display.backingScale <= 4,
                       "scale \(display.backingScale) on display \(display.displayID) is implausible")
            }
        }

        // The bug itself. A Retina display must not report 1.0.
        test("a Retina display does not report a backing scale of 1") {
            let all = CaptureEngine.displays()
            expect(!all.isEmpty, "nothing enumerated, so the assertion cannot fail")
            // The loop below can only say something if a display is actually scaled. It used to
            // ask `CGDisplayPixelsWide > frame.width`, which is never true — that API returns
            // *points*, the exact trap invariant 1 records — so the loop body never ran and the
            // test ticked green while checking nothing. The scale itself is the honest question.
            expect(all.contains { $0.backingScale > 1 },
                   "no display on this Mac reports a scale above 1, so the Retina assertion below "
                     + "has nothing to check — run this on the built-in display, or delete the case")
            for display in all {
                let capturedPixelsWide = CGDisplayPixelsWide(display.displayID)
                let pointWidth = Int(display.frame.width)
                if capturedPixelsWide > pointWidth {
                    // The OS reports more pixels than points, so the display is scaled and
                    // Chunks must know it.
                    expect(display.backingScale > 1,
                           "display \(display.displayID) has \(capturedPixelsWide) px across "
                           + "\(pointWidth) pt but Chunks reports scale \(display.backingScale) — "
                           + "every click will land at the wrong offset")
                }
            }
        }

        asyncTest("the reported scale matches what capture actually returns") {
            // The only check that cannot lie: capture the display and compare the image's
            // pixel width against the reported scale. This is why `ScreenCapture` measures
            // its own scale rather than trusting the display's.
            guard CaptureEngine.hasScreenRecordingPermission() else {
                // Reported as a skip, not a pass. This is the only check that cannot lie about the
                // scale, and a run that reports it green without capturing anything is the exact
                // false assurance that let the `CGDisplayPixelsWide` bug through.
                skipTest("no Screen Recording permission for this binary")
                return
            }
            guard let display = CaptureEngine.mainDisplay() else {
                expect(false, "no main display")
                return
            }
            do {
                let capture = try await CaptureEngine().capture(display: display)
                let expected = Int(display.frame.width * display.backingScale)
                // Allow a pixel: rounded display dimensions do not divide evenly.
                expect(abs(capture.image.width - expected) <= 1,
                       "display says \(display.backingScale)x so \(display.frame.width) pt "
                       + "should be \(expected) px, but capture returned \(capture.image.width)")
                expectEqual(capture.measuredScale, display.backingScale,
                            "measured scale disagrees with the reported display scale")
            } catch {
                expect(false, "capture failed: \(error)")
            }
        }

        test("displays are ordered main first") {
            let all = CaptureEngine.displays()
            guard let mainIndex = all.firstIndex(where: { $0.isMain }) else {
                expect(!all.isEmpty, "no displays at all")
                return
            }
            expectEqual(mainIndex, 0, "the main display should come first so index 1 means main")
        }

        test("exactly one display is marked main") {
            let all = CaptureEngine.displays()
            expectEqual(all.filter { $0.isMain }.count, 1,
                        "a zero or multiple main display breaks screenN resolution")
        }

        test("screenN resolves to a real display, 1-based") {
            let all = CaptureEngine.displays()
            for (offset, display) in all.enumerated() {
                expectEqual(CaptureEngine.display(index: offset + 1)?.displayID, display.displayID,
                            "screenN \(offset + 1) should resolve to display \(display.displayID)")
            }
            expect(CaptureEngine.display(index: 0) == nil, "screenN is 1-based; 0 must be nil")
            expect(CaptureEngine.display(index: all.count + 1) == nil, "out-of-range screenN must be nil")
        }

        test("display frames use the CoreGraphics top-left origin") {
            expect(!CaptureEngine.displays().isEmpty, "nothing enumerated to check the origin of")
            // The main display's origin is (0,0) in CG space. A second display to the left
            // would be negative. This test documents the convention so a future change to
            // AppKit's bottom-left convention cannot slip in unnoticed.
            guard let main = CaptureEngine.mainDisplay() else { return }
            expect(main.frame.minX == 0 && main.frame.minY == 0,
                   "the main display should start at the global origin, got \(main.frame)")
        }

        test("a display's space converts using its own scale") {
            guard let display = CaptureEngine.mainDisplay() else { return }
            let space = display.space
            let point = LogicalPoint(x: 100, y: 100)
            let device = space.devicePoint(for: point)
            expectEqual(space.logicalPoint(for: device), point, "round trip failed")
        }
    }
}
