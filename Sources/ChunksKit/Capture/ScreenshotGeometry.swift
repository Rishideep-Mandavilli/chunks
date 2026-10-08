import CoreGraphics
import Foundation

/// Maps the point a model aimed at into a display's coordinate space.
///
/// The model sees a *resized* screenshot — `CompanionScreenCapture` caps the image it sends at
/// 1280 on the long edge — so its coordinates are neither device pixels nor logical points, and
/// the only sound mapping is proportional: the fraction of the way across the image is the
/// fraction of the way across the display. Doing it any other way is the Retina double-offset bug
/// invariant 1 exists to prevent, and it produces a plausible number rather than an error.
///
/// **The fraction is taken over a 0–1000 grid, not over the image's pixel size, because that is
/// the space the model actually answers in.** Measured 2026-10-04 against a 1280x829 image of a
/// 1710x1107 display: asked for WhatsApp's send button — which sits at image pixel (1238, 814) —
/// it answered `(955, 975)`, `(955, 977)` and `(956, 974)` on three separate turns. Those are not
/// pixels: 975 is 118% of an image that is only 829 rows tall, and 955/1000 and 975/1000 land on
/// the button to within a few points. Divided by the image size instead, every one of those aims
/// clamped to the bottom edge of the screen, no window contains that row, and the user read "That
/// app did not expose a control at that point" three times for a button plainly on screen. The
/// same compression explains a press landing on the neighbour of the row it was asked about.
///
/// A number above 1000 cannot come from the grid, so such a reply is read as pixels — the model
/// used the dimensions in the image label after all — and the log says which space was used.
public enum ScreenshotGeometry {

    /// The edge of the grid a model is asked to aim in: 0 is one border, 1000 the other.
    public static let gridEdge = 1000.0

    public enum AimSpace: Equatable, Sendable {
        /// A 0–1000 grid stretched over the image.
        case grid
        /// Pixels of the image the model was shown.
        case imagePixels
    }

    /// Which space a pair of numbers came back in.
    ///
    /// Decided by the pair, not per coordinate: a reply with one impossible value was written in
    /// the other space throughout, and rescaling only that axis would shear the aim.
    public static func aimSpace(x: Double, y: Double) -> AimSpace {
        max(abs(x), abs(y)) > gridEdge ? .imagePixels : .grid
    }

    /// The text appended to an image label, so the space to answer in is stated next to the
    /// picture instead of being remembered from a system prompt three screens away.
    ///
    /// Both numbers appear on purpose: the pixel size tells the model what it is looking at, and
    /// the grid tells it what to answer in. The measured failure is answering in the first — the
    /// same ask came back as `(955, 975)` for a control at image pixel `(1238, 814)`, three turns
    /// running, because 955 and 975 are that button's grid coordinates.
    public static func coordinateSpaceNote(imageWidth: Int, imageHeight: Int) -> String {
        "(image \(imageWidth)x\(imageHeight) px — aim in a 0–1000 grid stretched over it, "
            + "not in pixels: (500,500) is the middle, (920,960) the bottom right)"
    }

    /// Aim coordinates (top-left origin) → AppKit global coordinates (bottom-left origin).
    ///
    /// `displayFrame` is the `NSScreen` frame, which is already bottom-left global. The flip
    /// happens here, once, so no caller has to reason about which Y convention it is holding.
    /// Returns `nil` for a degenerate image, because dividing by a zero width would otherwise
    /// hand back `NaN` and a `NaN` coordinate lands a press nowhere at all.
    public static func appKitGlobalPoint(x: Double,
                                         y: Double,
                                         imageWidth: Double,
                                         imageHeight: Double,
                                         displayFrame: CGRect) -> CGPoint? {
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        let space = aimSpace(x: x, y: y)
        let extentX = space == .grid ? gridEdge : imageWidth
        let extentY = space == .grid ? gridEdge : imageHeight

        let fx = min(max(x / extentX, 0), 1)
        let fy = min(max(y / extentY, 0), 1)

        let width = Double(displayFrame.width)
        let height = Double(displayFrame.height)
        // Half a point inside the display on every side. An aim that lands on the last row of the
        // image — which is what an input bar at the bottom of the screen looks like to the model —
        // must still be over a window: `CGWindowListCopyWindowInfo` bounds and AX hit tests are
        // exclusive at the far edge, so a point *on* the edge resolves to nothing and the press is
        // refused for a control the user can see.
        let localX = min(max(fx * width, 0.5), width - 0.5)
        // Image Y runs downward from the top of the display; AppKit Y runs upward from its
        // bottom, so the fraction is inverted before it is scaled.
        let localYFromBottom = min(max((1 - fy) * height, 0.5), height - 0.5)

        return CGPoint(x: displayFrame.minX + localX,
                       y: displayFrame.minY + localYFromBottom)
    }

    /// AppKit global (bottom-left) → the top-left global space the Accessibility API hit-tests
    /// in. `primaryScreenHeight` is the height of the screen that owns the global origin —
    /// `NSScreen.screens.first`, whose frame origin is (0, 0) by definition.
    public static func axGlobalPoint(appKitGlobalPoint point: CGPoint,
                                     primaryScreenHeight: Double) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }
}
