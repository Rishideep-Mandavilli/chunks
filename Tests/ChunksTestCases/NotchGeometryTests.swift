import ChunksTestHarness
@testable import ChunksKit

/// Geometry for the notch-anchored HUD.
///
/// The numbers below are the real ones a 14" MacBook Pro reports in points: a 1512x982
/// display, a 184 pt notch, 32 pt of depth, a 664 pt menu-bar strip on either side. Using
/// actual measurements rather than round numbers matters here — several of the bugs this
/// file guards against come from assuming the notch is at the display's center or that its
/// width is a constant.
public enum NotchGeometryTests {

    private static func notched(width: Double = 1512,
                                height: Double = 982,
                                notchWidth: Double = 184,
                                safeAreaTop: Double = 32,
                                stripHeight: Double = 32,
                                menuBar: Double = 24) -> ScreenTopProbe {
        let strip = (width - notchWidth) / 2
        return ScreenTopProbe(
            screenBounds: LogicalRect(x: 0, y: 0, width: width, height: height),
            safeAreaTop: safeAreaTop,
            leftAuxiliary: LogicalRect(x: 0, y: 0, width: strip, height: stripHeight),
            rightAuxiliary: LogicalRect(x: strip + notchWidth, y: 0, width: strip, height: stripHeight),
            menuBarHeight: menuBar
        )
    }

    private static func plain(width: Double = 1920, height: Double = 1080, menuBar: Double = 24) -> ScreenTopProbe {
        ScreenTopProbe(screenBounds: LogicalRect(x: 0, y: 0, width: width, height: height),
                       safeAreaTop: 0,
                       leftAuxiliary: nil,
                       rightAuxiliary: nil,
                       menuBarHeight: menuBar)
    }

    public static func register() {
        TestRunner.currentSuite = "NotchGeometry"

        // MARK: Detecting the cutout

        test("notch width is the gap between the two menu-bar strips") {
            let g = NotchGeometry(notched())
            expect(g.hasNotch, "a notched display was reported as flat")
            expectEqual(g.notchWidth, 184)
            expectEqual(g.notchHeight, 32)
        }

        test("a display with no auxiliary areas has no notch") {
            let g = NotchGeometry(plain())
            expect(!g.hasNotch)
            expectEqual(g.notchWidth, 0)
            expectEqual(g.notchHeight, 0)
        }

        test("one missing strip is not a notch") {
            var probe = plain()
            probe.leftAuxiliary = LogicalRect(x: 0, y: 0, width: 664, height: 32)
            expect(!NotchGeometry(probe).hasNotch,
                   "a single strip means the pair was misread, not that half a notch exists")
        }

        test("zero safe-area depth falls back to the strip height") {
            let g = NotchGeometry(notched(safeAreaTop: 0, stripHeight: 30))
            expect(g.hasNotch)
            expectEqual(g.notchHeight, 30)
        }

        test("strips that touch or overlap are not a notch") {
            // rightAux.minX == leftAux.maxX: no gap, so the "cutout" is zero wide.
            let touching = ScreenTopProbe(
                screenBounds: LogicalRect(x: 0, y: 0, width: 1512, height: 982),
                safeAreaTop: 32,
                leftAuxiliary: LogicalRect(x: 0, y: 0, width: 756, height: 32),
                rightAuxiliary: LogicalRect(x: 756, y: 0, width: 756, height: 32),
                menuBarHeight: 24)
            expect(!NotchGeometry(touching).hasNotch)
        }

        test("a gap wider than half the screen is a misread, not a notch") {
            // 1000 of 1512 points: no bezel is that wide. Treating it as one would center
            // the HUD over dead space; the menu-bar path always has somewhere to draw.
            let g = NotchGeometry(notched(notchWidth: 1000))
            expect(!g.hasNotch, "an implausibly wide gap must degrade to the fallback")
            expectEqual(g.hudCenterX, 756, "and then center on the display")
        }

        // MARK: Anchoring

        test("a notched HUD starts flush with the top of the screen") {
            expectEqual(NotchGeometry(notched()).hudTop, 0,
                        "an inset top edge makes the panel read as detached from the notch")
        }

        test("a fallback HUD sits below the menu bar") {
            expectEqual(NotchGeometry(plain()).hudTop, 24,
                        "on a flat display the HUD must not cover the clock and menu extras")
        }

        test("the HUD centers on the notch, not on the display") {
            // An asymmetric cutout: left strip 600, right strip starts at 784.
            let probe = ScreenTopProbe(
                screenBounds: LogicalRect(x: 0, y: 0, width: 1512, height: 982),
                safeAreaTop: 32,
                leftAuxiliary: LogicalRect(x: 0, y: 0, width: 600, height: 32),
                rightAuxiliary: LogicalRect(x: 784, y: 0, width: 728, height: 32),
                menuBarHeight: 24)
            let g = NotchGeometry(probe)
            expectEqual(g.notchWidth, 184)
            expectEqual(g.hudCenterX, 692, "expected the notch mid, got the display mid")
        }

        // MARK: Card rects

        test("a card narrower than the notch is widened to cover it") {
            let g = NotchGeometry(notched())
            let r = g.hudRect(width: 120, height: 40)
            expectEqual(r.width, 184,
                        "a card inside the cutout's width leaves notch bezel biting into it")
        }

        test("a wide card is centered on the notch") {
            let g = NotchGeometry(notched())
            let r = g.hudRect(width: 320, height: 300)
            expectEqual(r.minX, 596)
            expectEqual(r.width, 320)
            expectEqual(r.minY, 0)
        }

        test("a card wider than the display is clamped, and its origin stays in bounds") {
            let g = NotchGeometry(notched(width: 800, notchWidth: 184))
            let r = g.hudRect(width: 1200, height: 200)
            expectEqual(r.width, 800)
            expectEqual(r.minX, 0)
        }

        test("an off-center notch cannot push the card off the edge") {
            // Notch hugging the left edge: centering a 320 card on it wants x = -120.
            let probe = ScreenTopProbe(
                screenBounds: LogicalRect(x: 0, y: 0, width: 1512, height: 982),
                safeAreaTop: 32,
                leftAuxiliary: LogicalRect(x: 0, y: 0, width: 20, height: 32),
                rightAuxiliary: LogicalRect(x: 204, y: 0, width: 1308, height: 32),
                menuBarHeight: 24)
            let r = NotchGeometry(probe).hudRect(width: 320, height: 120)
            expectEqual(r.minX, 0, "negative x would draw the card off-display")
            expectEqual(r.width, 320, "clamping x must not shrink the card")
        }

        // MARK: Coordinate flip

        test("the local-to-window flip converts top-left screen space into AppKit's bottom-left global space") {
            // A secondary display sits 1080 points below the primary, so its global origin
            // is (0, -1080) while its local top-left is (0, 0).
            let globalScreen = LogicalRect(x: 0, y: -1080, width: 1920, height: 1080)
            let local = LogicalRect(x: 800, y: 0, width: 320, height: 240)

            let frame = NotchGeometry.appKitWindowFrame(local, globalScreen: globalScreen)

            expectEqual(frame.minX, 800)
            expectEqual(frame.width, 320)
            expectEqual(frame.height, 240)
            // Top of the display is global y = 0; the panel's *origin* is its bottom edge,
            // 240 down from there.
            expectEqual(frame.minY, -240)
            expectEqual(frame.maxY, 0, "the card's top edge must land exactly on the display's top")
        }

        test("the fallback offset survives the flip") {
            let globalScreen = LogicalRect(x: 0, y: 0, width: 1920, height: 1080)
            let g = NotchGeometry(plain())
            let frame = NotchGeometry.appKitWindowFrame(g.hudRect(width: 320, height: 100),
                                                        globalScreen: globalScreen)
            expectEqual(frame.maxY, 1056, "24 pt of menu bar must come off the top, not the bottom")
        }
    }
}
